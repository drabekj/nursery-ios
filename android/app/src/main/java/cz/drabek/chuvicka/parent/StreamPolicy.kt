package cz.drabek.chuvicka.parent

/** Which stream to ask for. Pure, so the unit tests can run it. The same rule as the iOS app. */
object StreamPolicy {
    data class Inputs(
        val wantsDetail: Boolean,   // The picture is big: landscape, not in the small window.
        val soundOnly: Boolean,     // The sound view, Night mode.
        val thermalHot: Boolean,    // PowerManager thermal status MODERATE or worse.
        val powerSave: Boolean,     // Battery Saver.
        val detailStream: String,
        val everydayStream: String,
    )

    /** The detail (main) stream only for a big picture on a phone that is cool and not saving power. */
    fun detail(i: Inputs): Boolean =
        i.wantsDetail && !i.soundOnly && !i.thermalHot && !i.powerSave && i.detailStream != i.everydayStream

    fun stream(i: Inputs): String = if (detail(i)) i.detailStream else i.everydayStream
}
