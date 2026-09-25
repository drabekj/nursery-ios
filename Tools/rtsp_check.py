#!/usr/bin/env python3
"""A line-by-line Python copy of Nursery/Stream/RTP.swift and the RTSP steps of RTSPClient.swift.

It connects to a go2rtc RTSP restream, and it proves the algorithms of the app:
  1. The handshake: OPTIONS, DESCRIBE, SETUP (interleaved), PLAY.
  2. The H.264 depacketizer. It writes the access units as Annex B. ffmpeg must decode them with no error.
  3. The G.711 table. It must match the decoder of ffmpeg, sample for sample.

Usage: rtsp_check.py rtsp://192.168.0.136:8554/nursery [seconds]
"""
import base64, math, os, re, socket, struct, subprocess, sys, tempfile, time

# ---- SDP (SDP.parse, SDP.controlURL) ----
def sdp_parse(text):
    tracks, sections = [], []
    for line in text.replace('\r', '').split('\n'):
        if line.startswith('m='): sections.append([line])
        elif sections: sections[-1].append(line)
    for sec in sections:
        m = sec[0][2:].split(' ')
        if len(m) < 4 or not m[3].isdigit(): continue
        pt = int(m[3]); kind = m[0] if m[0] in ('video', 'audio') else 'other'
        codec, rate, control, fmtp = '', 0, '', {}
        for line in sec[1:]:
            if line.startswith(f'a=rtpmap:{pt} '):
                parts = line.split(' ', 1)[1].split('/'); codec = parts[0].upper(); rate = int(parts[1]) if len(parts) > 1 else 0
            elif line.startswith(f'a=fmtp:{pt} '):
                for item in line.split(' ', 1)[1].split(';'):
                    kv = item.strip()
                    if '=' in kv: k, v = kv.split('=', 1); fmtp[k.lower()] = v
            elif line.startswith('a=control:'): control = line[len('a=control:'):]
        if not codec:
            codec, rate = {0: ('PCMU', 8000), 8: ('PCMA', 8000)}.get(pt, ('', 0))
        tracks.append(dict(kind=kind, pt=pt, codec=codec, rate=rate, control=control, fmtp=fmtp))
    return tracks

def h264_parameter_sets(track):
    sps = pps = None
    for part in track['fmtp'].get('sprop-parameter-sets', '').split(','):
        b = part.strip(); b += '=' * ((4 - len(b) % 4) % 4)
        try: data = base64.b64decode(b)
        except Exception: continue
        if not data: continue
        if data[0] & 0x1F == 7: sps = data
        if data[0] & 0x1F == 8: pps = data
    return (sps, pps) if sps and pps else None

def control_url(base, control):
    if not control or control == '*': return base
    if control.lower().startswith('rtsp://'): return control
    return base + control if base.endswith('/') else base + '/' + control

# ---- RTP (RTPPacket.init) ----
def rtp_parse(b):
    if len(b) < 12 or b[0] >> 6 != 2: return None
    start, end = 12 + 4 * (b[0] & 0x0F), len(b)
    if b[0] & 0x10:
        if len(b) < start + 4: return None
        start += 4 + 4 * (b[start + 2] << 8 | b[start + 3])
    if b[0] & 0x20: end -= b[-1]
    if start > end: return None
    return dict(pt=b[1] & 0x7F, marker=bool(b[1] & 0x80), seq=b[2] << 8 | b[3],
                ts=struct.unpack('>I', b[4:8])[0], payload=b[start:end])

# ---- H.264 (H264Depacketizer) ----
class H264Depacketizer:
    def __init__(self): self.sps = self.pps = None; self.version = 0; self.nals = []; self.fragment = None; self.ts = None; self.last_seq = None; self.damaged = False; self.dropped = 0; self.wait_key = False
    def set_parameter_sets(self, sps, pps):
        if sps != self.sps or pps != self.pps: self.sps, self.pps = sps, pps; self.version += 1
    def push(self, p):
        out = None
        if self.last_seq is not None and p['seq'] != (self.last_seq + 1) & 0xFFFF: self.damaged = True; self.fragment = None
        self.last_seq = p['seq']
        if self.ts is not None and self.ts != p['ts'] and self.nals: out = self.flush()
        self.ts = p['ts']
        pl = p['payload']
        if not pl: return out
        t = pl[0] & 0x1F
        if 1 <= t <= 23: self.add(bytes(pl))
        elif t == 24:
            i = 1
            while i + 2 <= len(pl):
                size = pl[i] << 8 | pl[i + 1]; i += 2
                if size == 0 or i + size > len(pl): break
                self.add(bytes(pl[i:i + size])); i += size
        elif t == 28 and len(pl) >= 2:
            h = pl[1]; body = pl[2:]
            if h & 0x80: self.fragment = bytes([(pl[0] & 0xE0) | (h & 0x1F)]) + body
            elif self.fragment is not None: self.fragment += body
            if h & 0x40 and self.fragment is not None: nal = self.fragment; self.fragment = None; self.add(nal)
        if p['marker'] and self.nals: out = self.flush()
        return out
    def add(self, nal):
        t = nal[0] & 0x1F
        if t == 7:
            if nal != self.sps: self.sps = nal; self.version += 1
        elif t == 8:
            if nal != self.pps: self.pps = nal; self.version += 1
        elif t == 9: pass
        else: self.nals.append(nal)
    def flush(self):
        nals, damaged = self.nals, self.damaged; self.nals = []; self.damaged = False
        if damaged or self.ts is None: self.dropped += 1; self.wait_key = True; return None
        key = any(n[0] & 0x1F == 5 for n in nals)
        if not any(1 <= n[0] & 0x1F <= 5 for n in nals): return None
        if self.wait_key:
            if not key: self.dropped += 1; return None
            self.wait_key = False
        return dict(nals=nals, ts=self.ts, key=key)

# ---- G.711 (G711.decodeALaw, G711.decodeULaw) ----
def decode_alaw(v):
    a = v ^ 0x55; t = (a & 0x0F) << 4; seg = (a & 0x70) >> 4
    if seg == 0: t += 8
    elif seg == 1: t += 0x108
    else: t += 0x108; t <<= seg - 1
    return t if a & 0x80 else -t
def decode_ulaw(v):
    u = ~v & 0xFF; t = ((u & 0x0F) << 3) + 0x84; t <<= (u & 0x70) >> 4
    return 0x84 - t if u & 0x80 else t - 0x84
ALAW = [decode_alaw(i) for i in range(256)]
ULAW = [decode_ulaw(i) for i in range(256)]

def level_from_rms(rms):  # LiveAudioPlayer.level(fromRMS:)
    db = 20 * math.log10(max(rms, 1e-6)); return min(1, max(0, (db + 58) / 46))

# ---- RTSP (RTSPClient.start and parse) ----
class RTSP:
    def __init__(self, url):
        m = re.match(r'rtsp://([^:/?]+)(?::(\d+))?', url); self.url = url
        self.sock = socket.create_connection((m[1], int(m[2] or 554)), 5); self.buf = b''; self.cseq = 0; self.session = None
    def fill(self):
        d = self.sock.recv(262144)
        if not d: raise EOFError('The server closed the connection.')
        self.buf += d
    def request(self, method, uri, headers=None):
        self.cseq += 1
        text = f'{method} {uri} RTSP/1.0\r\nCSeq: {self.cseq}\r\nUser-Agent: Nursery/1.0\r\n'
        if self.session: text += f'Session: {self.session}\r\n'
        for k, v in (headers or {}).items(): text += f'{k}: {v}\r\n'
        self.sock.sendall((text + '\r\n').encode())
        while True:
            while b'\r\n\r\n' not in self.buf: self.fill()
            if self.buf[0] == 0x24: self.frame(); continue
            head, _, rest = self.buf.partition(b'\r\n\r\n'); lines = head.decode().split('\r\n')
            status = lines[0].split(' ', 2); hdr = {}
            for l in lines[1:]:
                if ':' in l: k, v = l.split(':', 1); hdr[k.lower()] = v.strip()
            n = int(hdr.get('content-length', 0))
            while len(rest) < n: self.fill(); head, _, rest = self.buf.partition(b'\r\n\r\n')
            self.buf = rest[n:]
            if int(hdr.get('cseq', -1)) == self.cseq:
                code = int(status[1])
                if not 200 <= code < 300: raise RuntimeError(f'{method}: {code} {status[2] if len(status) > 2 else ""}')
                return hdr, rest[:n].decode()
    def frame(self):
        while len(self.buf) < 4: self.fill()
        if self.buf[0] != 0x24: raise RuntimeError('out of step')
        ch, n = self.buf[1], self.buf[2] << 8 | self.buf[3]
        while len(self.buf) < 4 + n: self.fill()
        pkt, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
        return ch, pkt
    def start(self):
        try: self.request('OPTIONS', self.url)
        except Exception: pass
        hdr, sdp = self.request('DESCRIBE', self.url, {'Accept': 'application/sdp'})
        base = hdr.get('content-base') or hdr.get('content-location') or self.url
        tracks = []
        for t in sdp_parse(sdp):
            usable = (t['kind'] == 'video' and t['codec'] == 'H264') or (t['kind'] == 'audio' and t['codec'] in ('PCMA', 'PCMU'))
            if not usable or any(x['kind'] == t['kind'] for x in tracks): continue
            ch = len(tracks) * 2
            h, _ = self.request('SETUP', control_url(base, t['control']), {'Transport': f'RTP/AVP/TCP;unicast;interleaved={ch}-{ch + 1}'})
            if self.session is None and 'session' in h: self.session = h['session'].split(';')[0].strip()
            t['channel'] = ch; tracks.append(t)
        if not tracks: raise RuntimeError('no usable track')
        self.request('PLAY', self.url, {'Range': 'npt=0.000-'})
        return sdp, tracks

def main():
    url = sys.argv[1]; seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 5
    loss = float(os.environ.get('LOSS', '0'))   # A test: drop this share of the video packets.
    import random; random.seed(1)
    c = RTSP(url); sdp, tracks = c.start()
    print('SDP tracks:', [(t['kind'], t['codec'], t['pt'], t['rate'], t['channel']) for t in tracks])
    video = next((t for t in tracks if t['kind'] == 'video'), None)
    audio = next((t for t in tracks if t['kind'] == 'audio'), None)
    dep = H264Depacketizer()
    if video and (sets := h264_parameter_sets(video)): dep.set_parameter_sets(*sets)
    annexb, alaw, units, keys, first_key_at = bytearray(), bytearray(), 0, 0, None
    waiting = True; t0 = time.time(); levels = []
    while time.time() - t0 < seconds:
        ch, pkt = c.frame(); p = rtp_parse(pkt)
        if p is None: continue
        if video and ch == video['channel']:
            if loss and random.random() < loss: continue
            u = dep.push(p)
            if not u: continue
            if waiting and not u['key']: continue          # VideoRenderer waits for a keyframe.
            if waiting: first_key_at = time.time() - t0; annexb += b'\0\0\0\1' + dep.sps + b'\0\0\0\1' + dep.pps
            waiting = False; units += 1; keys += u['key']
            for n in u['nals']: annexb += b'\0\0\0\1' + n
        elif audio and ch == audio['channel']:
            table = ULAW if audio['codec'] == 'PCMU' else ALAW
            s = [table[b] / 32768 for b in p['payload']]
            levels.append(level_from_rms(math.sqrt(sum(x * x for x in s) / len(s))))
            alaw += p['payload']
    ok = True
    with tempfile.TemporaryDirectory() as d:
        if video:
            path = os.path.join(d, 'v.h264'); open(path, 'wb').write(annexb)
            r = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'h264', '-i', path, '-f', 'null', '-'], capture_output=True, text=True)
            frames = subprocess.run(['ffprobe', '-v', 'error', '-count_frames', '-select_streams', 'v:0', '-show_entries',
                                     'stream=nb_read_frames,width,height', '-of', 'csv=p=0', path], capture_output=True, text=True).stdout.strip()
            print(f'video: {units} access units, {keys} keyframes, first keyframe after {first_key_at:.2f} s, '
                  f'{dep.dropped} damaged frames dropped; ffprobe (w,h,frames) = {frames}; ffmpeg errors: {r.stderr.strip() or "none"}')
            ok &= units > 0 and not r.stderr.strip()
        if audio:
            path = os.path.join(d, 'a.raw'); open(path, 'wb').write(alaw)
            fmt = 'mulaw' if audio['codec'] == 'PCMU' else 'alaw'
            ref = subprocess.run(['ffmpeg', '-v', 'error', '-f', fmt, '-ar', '8000', '-ac', '1', '-i', path, '-f', 's16le', '-'], capture_output=True).stdout
            ref = struct.unpack(f'<{len(ref) // 2}h', ref)
            table = ULAW if fmt == 'mulaw' else ALAW
            mismatch = sum(1 for b, r in zip(alaw, ref) if table[b] != r)
            print(f'audio: {len(alaw)} samples ({len(alaw) / 8000:.1f} s), G.711 mismatches against ffmpeg: {mismatch}, '
                  f'level min/mean/max = {min(levels):.2f}/{sum(levels) / len(levels):.2f}/{max(levels):.2f}')
            ok &= len(alaw) > 0 and mismatch == 0
    print('RESULT:', 'PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
