package cz.drabek.chuvicka.parent

import android.content.Context
import cz.drabek.chuvicka.Log
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import java.util.Locale
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger

/** The pure parts of the cry classifier: the resampling, the verdict, the labels. Unit tested. */
object Yamnet {
    /** The model's input: 15600 samples at 16 kHz (0.975 s)... */
    const val WINDOW = 15_600
    /** ...and a new window every 0.5 s. */
    const val HOP = 8_000
    const val CLASSES = 521
    /** "Baby cry, infant cry" and "Crying, sobbing" in yamnet_class_map.csv. */
    const val BABY_CRY = 20
    const val CRYING = 19
    /** A cry: "Baby cry" at least 0.35, or "Crying, sobbing" at least 0.5. */
    const val BABY_CRY_MIN = 0.35f
    const val CRYING_MIN = 0.5f

    /**
     * 8 kHz to 16 kHz by linear interpolation: before each sample, the mean with the one before.
     * Writes 2 × [count] samples to [out]. Returns the last sample: the [previous] of the next call.
     * The G.711 sound has no content above 4 kHz, so the model hears less than it was trained on.
     */
    fun upsample(input: FloatArray, count: Int, previous: Float, out: FloatArray): Float {
        var prev = previous
        for (i in 0 until count) {
            val x = input[i]
            out[2 * i] = (prev + x) * 0.5f
            out[2 * i + 1] = x
            prev = x
        }
        return prev
    }

    /** The verdict for the 521 scores of one window. Else: the best class, for the log. */
    fun verdict(scores: FloatArray, labels: List<String>): CryVerdict {
        if (scores[BABY_CRY] >= BABY_CRY_MIN) return CryVerdict.Cry(scores[BABY_CRY])
        if (scores[CRYING] >= CRYING_MIN) return CryVerdict.Cry(scores[CRYING])
        var best = 0
        for (i in scores.indices) if (scores[i] > scores[best]) best = i
        return CryVerdict.Other(labels.getOrNull(best) ?: "class $best", scores[best])
    }

    /** The log line of a verdict: "cry: baby_cry 0.61", "cry: other Speech 0.40". */
    fun describe(verdict: CryVerdict, scores: FloatArray): String = when (verdict) {
        is CryVerdict.Cry -> "cry: ${if (scores[BABY_CRY] >= BABY_CRY_MIN) "baby_cry" else "crying_sobbing"} ${"%.2f".format(Locale.US, verdict.confidence)}"
        is CryVerdict.Other -> "cry: other ${verdict.label} ${"%.2f".format(Locale.US, verdict.confidence)}"
    }

    /** yamnet_class_map.csv: "index,mid,display_name", the name in quotes when it has a comma. */
    fun labels(csv: String): List<String> = csv.lineSequence().drop(1).filter { it.isNotBlank() }
        .map { it.split(",", limit = 3).getOrElse(2) { "" }.trim().removeSurrounding("\"") }
        .toList()
}

/** The sliding window of the model: [size] samples; [full] gets it every [hop] new samples. */
class SlidingWindow(val size: Int, val hop: Int, private val full: (FloatArray) -> Unit) {
    private val samples = FloatArray(size)
    private var filled = 0

    fun add(src: FloatArray, count: Int) {
        var i = 0
        while (i < count) {
            val n = minOf(count - i, size - filled)
            System.arraycopy(src, i, samples, filled, n)
            filled += n
            i += n
            if (filled == size) {
                full(samples)
                System.arraycopy(samples, hop, samples, 0, size - hop)
                filled = size - hop
            }
        }
    }

    fun clear() { filled = 0 }
}

/**
 * The cry classifier: YAMNet (TensorFlow Lite) on the decoded sound of the baby's room.
 * It runs only while a sound event runs ([setActive]), so nothing runs in a quiet room.
 * One thread of its own does all the work; the verdicts go to [verdicts], which the tick drains.
 * Any failure of the model: [available] is false, and the loudness rule decides (RoomStateMachine).
 */
class CryDetector(private val context: Context) {
    /** False after the model failed to load or to run. */
    @Volatile var available = true
        private set
    /** The verdicts, newest last. The monitor's tick takes them. */
    val verdicts = ConcurrentLinkedQueue<CryVerdict>()
    /** A sound event runs and the model works: the monitor hands over the samples. */
    val wanted get() = active && available

    @Volatile private var active = false
    @Volatile private var closed = false
    private val pending = AtomicInteger()
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "cry").apply { isDaemon = true; priority = Thread.NORM_PRIORITY - 1 }
    }

    // Only on the executor thread.
    private var interpreter: Interpreter? = null
    private var labels: List<String> = emptyList()
    private var input: ByteBuffer? = null
    private var inputFloats: FloatBuffer? = null
    private var output: ByteBuffer? = null
    private var outputFloats: FloatBuffer? = null
    private var frames = 1
    private val scores = FloatArray(Yamnet.CLASSES)
    private var previous = 0f
    private var upsampled = FloatArray(0)
    private var dropped = false
    private val window = SlidingWindow(Yamnet.WINDOW, Yamnet.HOP) { classify(it) }

    /** A sound event starts or ends. The first start loads the model. */
    fun setActive(on: Boolean) {
        if (on == active) return
        active = on
        if (on) {
            execute { load() }
        } else {
            verdicts.clear()
            execute { window.clear(); previous = 0f }
        }
    }

    /** The decoded samples of one packet (8 kHz, -1...1). The array is the detector's now. */
    fun feed(samples: FloatArray) {
        if (!wanted) return
        // The model cannot keep up (a slow phone): drop the sound rather than pile it up.
        if (pending.get() > MAX_PENDING) {
            if (!dropped) { dropped = true; Log.add("cry: the classifier is slow, some sound skipped") }
            return
        }
        pending.incrementAndGet()
        execute { pending.decrementAndGet(); process(samples) }
    }

    /** The service stops: close the model and the thread. */
    fun close() {
        active = false
        verdicts.clear()
        execute { interpreter?.close(); interpreter = null }
        closed = true
        executor.shutdown()
    }

    private fun execute(task: () -> Unit) {
        if (closed) return
        try { executor.execute(task) } catch (_: RejectedExecutionException) {}
    }

    private fun process(samples: FloatArray) {
        if (!active || interpreter == null) return
        if (upsampled.size < samples.size * 2) upsampled = FloatArray(samples.size * 2)
        previous = Yamnet.upsample(samples, samples.size, previous, upsampled)
        window.add(upsampled, samples.size * 2)
    }

    private fun load() {
        if (interpreter != null || !available || closed) return
        try {
            val i = Interpreter(model(), Interpreter.Options().setNumThreads(1))
            // The model of the lead is [15600]; another export may have a free size.
            val shape = i.getInputTensor(0).shape()
            if (!(shape.size == 1 && shape[0] == Yamnet.WINDOW)) i.resizeInput(0, intArrayOf(Yamnet.WINDOW))
            i.allocateTensors()
            val out = i.getOutputTensor(0)
            val count = out.numElements()
            if (out.dataType() != DataType.FLOAT32 || count < Yamnet.CLASSES || count % Yamnet.CLASSES != 0) {
                i.close()
                throw IllegalStateException("output ${out.dataType()} ${out.shape().contentToString()}")
            }
            frames = count / Yamnet.CLASSES
            input = ByteBuffer.allocateDirect(Yamnet.WINDOW * 4).order(ByteOrder.nativeOrder()).also { inputFloats = it.asFloatBuffer() }
            output = ByteBuffer.allocateDirect(out.numBytes()).order(ByteOrder.nativeOrder()).also { outputFloats = it.asFloatBuffer() }
            labels = try {
                context.assets.open(LABELS).bufferedReader().use { Yamnet.labels(it.readText()) }
            } catch (_: Exception) {
                emptyList()
            }
            interpreter = i
            Log.add("cry: model ready, input ${shape.contentToString()}, output ${out.shape().contentToString()}")
        } catch (t: Throwable) {
            fail("load", t)
        }
    }

    /** The model file, mapped from the APK (it is stored uncompressed, see build.gradle.kts). */
    private fun model(): MappedByteBuffer = context.assets.openFd(MODEL).use { fd ->
        FileInputStream(fd.fileDescriptor).use { it.channel.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength) }
    }

    private fun classify(samples: FloatArray) {
        val i = interpreter ?: return
        val input = input ?: return
        val output = output ?: return
        val inputFloats = inputFloats ?: return
        val outputFloats = outputFloats ?: return
        try {
            inputFloats.rewind()
            inputFloats.put(samples)
            input.rewind()
            output.rewind()
            i.run(input, output)
            // Several frames (another export): the mean score of each class.
            for (c in 0 until Yamnet.CLASSES) {
                var sum = 0f
                for (f in 0 until frames) sum += outputFloats.get(f * Yamnet.CLASSES + c)
                scores[c] = sum / frames
            }
            val verdict = Yamnet.verdict(scores, labels)
            if (active) verdicts.add(verdict)
            Log.add(Yamnet.describe(verdict, scores))
        } catch (t: Throwable) {
            fail("run", t)
        }
    }

    private fun fail(where: String, t: Throwable) {
        available = false
        verdicts.clear()
        Log.add("cry: classifier off ($where: ${t.javaClass.simpleName} ${t.message ?: ""}), the loudness rule decides")
        try { interpreter?.close() } catch (_: Throwable) {}
        interpreter = null
    }

    private companion object {
        const val MODEL = "yamnet.tflite"
        const val LABELS = "yamnet_class_map.csv"
        /** About 2 s of packets (20 ms each). */
        const val MAX_PENDING = 100
    }
}
