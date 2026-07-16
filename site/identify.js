// identify.js -- RFC #62 Rung 2: identify a router from its Gargoyle
// config backup. A backup tarball (System->Backup) contains /etc/config/*
// but NO board_name file (verified against create_backup.sh -- neither
// /etc/board.json nor /etc/gargoyle_version is in its file list), so
// identification works from the signals the backup actually carries:
//
//   1. /etc/config/wireless "option path" values -- device-tree paths for
//      each radio, matched against devices/*.json fingerprints.wifi_paths.
//      Strongest signal available, but NOT unique per board (every ath79
//      board reports platform/ahb/18100000.wmac), so results are RANKED
//      CANDIDATES, never a single confident answer.
//   2. wireless "option band" vs "option hwmode" -- band replaced hwmode in
//      OpenWrt 21.02, so band => Gargoyle 1.13+, hwmode => 1.12 or older.
//      That era estimate drives the upgradable_from routing message.
//
// Everything runs client-side: DecompressionStream("gzip") (native in every
// current browser -- no bundled inflate library, and GitHub Pages CSP-free
// static hosting means no server to upload to either; the backup, which
// contains password hashes, never leaves the machine).
//
// Tar parsing is deliberately minimal: 512-byte headers, name at offset 0,
// size as octal at 124, content padded to 512. busybox tar (which wrote the
// backup) strips the leading "/" so members appear as "etc/config/...";
// matching is by suffix to be safe either way.
"use strict";

var GargoyleIdentify = (function () {

	function parseTar(buf) {
		var view = new Uint8Array(buf);
		var files = {};
		var td = new TextDecoder();
		var off = 0;
		while (off + 512 <= view.length) {
			var name = td.decode(view.subarray(off, off + 100)).replace(/\0.*$/, "");
			if (!name) break; // two zero blocks end the archive
			var sizeStr = td.decode(view.subarray(off + 124, off + 136)).replace(/\0.*$/, "").trim();
			var size = parseInt(sizeStr, 8) || 0;
			var type = String.fromCharCode(view[off + 156]);
			// ustar prefix field (some tars split long paths)
			var prefix = td.decode(view.subarray(off + 345, off + 500)).replace(/\0.*$/, "");
			var full = prefix ? prefix + "/" + name : name;
			if (type === "0" || type === "\0" || type === "") {
				files[full] = view.subarray(off + 512, off + 512 + size);
			}
			off += 512 + Math.ceil(size / 512) * 512;
		}
		return files;
	}

	function findMember(files, suffix) {
		var keys = Object.keys(files);
		for (var i = 0; i < keys.length; i++) {
			var k = keys[i].replace(/^\.\//, "").replace(/^\//, "");
			if (k === suffix || k.endsWith("/" + suffix)) return files[keys[i]];
		}
		return null;
	}

	// Just enough UCI parsing for what identification needs: every
	// "option <key> '<value>'" in the file, values collected per key.
	function uciOptions(text) {
		var out = {};
		text.split("\n").forEach(function (line) {
			var m = line.match(/^\s*option\s+(\S+)\s+'([^']*)'/) ||
			        line.match(/^\s*option\s+(\S+)\s+"([^"]*)"/) ||
			        line.match(/^\s*option\s+(\S+)\s+(\S+)\s*$/);
			if (m) (out[m[1]] = out[m[1]] || []).push(m[2]);
		});
		return out;
	}

	function gunzip(file) {
		// gzip magic 1f 8b; a plain .tar (unlikely but cheap to allow) is
		// passed through untouched.
		return file.arrayBuffer().then(function (raw) {
			var head = new Uint8Array(raw.slice(0, 2));
			if (head[0] !== 0x1f || head[1] !== 0x8b) return raw;
			if (typeof DecompressionStream === "undefined") {
				throw new Error("this browser lacks DecompressionStream (gzip) -- try a current Firefox/Chrome/Safari");
			}
			var ds = new DecompressionStream("gzip");
			var stream = new Blob([raw]).stream().pipeThrough(ds);
			return new Response(stream).arrayBuffer();
		});
	}

	// Jaccard over wifi path sets: candidates share ancestry (SoC family),
	// so the score expresses "how much of what this board would write did
	// the backup actually contain, and vice versa".
	function scoreDevice(backupPaths, devicePaths) {
		if (!devicePaths || devicePaths.length === 0) return 0;
		var inter = 0;
		var set = {};
		devicePaths.forEach(function (p) { set[p] = true; });
		backupPaths.forEach(function (p) { if (set[p]) inter++; });
		var union = devicePaths.length + backupPaths.length - inter;
		return union === 0 ? 0 : inter / union;
	}

	function analyze(file, indexEntries) {
		return gunzip(file).then(function (buf) {
			var files = parseTar(buf);
			var td = new TextDecoder();

			var wirelessRaw = findMember(files, "etc/config/wireless");
			if (!wirelessRaw) {
				return {
					ok: false,
					reason: "no etc/config/wireless inside this archive -- is it really a Gargoyle backup tarball?",
					memberCount: Object.keys(files).length
				};
			}
			var wireless = uciOptions(td.decode(wirelessRaw));
			var paths = wireless.path || [];

			// band (21.02+/Gargoyle 1.13+) vs hwmode (older)
			var era = null;
			if (wireless.band && wireless.band.length) {
				era = { label: "Gargoyle 1.13 or newer", detail: "wireless config uses the modern band option (OpenWrt 21.02+)" };
			} else if (wireless.hwmode && wireless.hwmode.length) {
				era = { label: "Gargoyle 1.12 or older", detail: "wireless config uses the legacy hwmode option (pre-OpenWrt 21.02)" };
			}

			var candidates = indexEntries
				.map(function (d) {
					var fp = d.fingerprints && d.fingerprints.wifi_paths;
					return { device: d, score: scoreDevice(paths, fp) };
				})
				.filter(function (c) { return c.score > 0; })
				.sort(function (a, b) { return b.score - a.score; })
				.slice(0, 5);

			return {
				ok: true,
				wifiPaths: paths,
				radioCount: paths.length,
				era: era,
				candidates: candidates
			};
		});
	}

	// Turn a matched device's upgradable_from routing + the era estimate
	// into the one instruction Rung 2 promises. Range keys are matched
	// coarsely: the era only tells us 1.13+ vs <=1.12, so pick the routing
	// entry whose range contains that side, defaulting to the safe manual
	// path when unsure.
	function routingAdvice(device, era) {
		var uf = device.upgradable_from;
		if (!uf) return null;
		if (uf["*"]) return uf["*"];
		var modern = era && era.label.indexOf("1.13") !== -1;
		var keys = Object.keys(uf);
		for (var i = 0; i < keys.length; i++) {
			var k = keys[i];
			if (modern && /^>=\s*1\.1[0-3]/.test(k)) return uf[k];
			if (!modern && (/^</.test(k) || /^1\.\d+\s*-\s*1\.\d+$/.test(k.replace(/\s/g, "")))) return uf[k];
		}
		return null;
	}

	return { analyze: analyze, routingAdvice: routingAdvice };
})();
