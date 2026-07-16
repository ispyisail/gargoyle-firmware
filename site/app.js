// app.js -- the Firmware Finder. Fetches ./index.json (built by
// scripts/make-index.sh) and renders a searchable, client-side-filtered list
// of devices and their release history. No build step, no external
// dependencies -- this file is served as-is by GitHub Pages.
//
// This same page is RFC #62's Rung-2 Firmware Finder: it's the one place a
// user on old firmware (which can't fetch a signed manifest itself) can find
// the right image by typing their model name.
"use strict";

(function () {
	var state = { data: null, channel: "all", query: "" };

	function $(sel, root) { return (root || document).querySelector(sel); }
	function el(tag, cls, text) {
		var e = document.createElement(tag);
		if (cls) e.className = cls;
		if (text != null) e.textContent = text;
		return e;
	}

	function humanSize(bytes) {
		if (bytes == null) return "";
		var units = ["B", "KB", "MB", "GB"];
		var i = 0, n = bytes;
		while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
		return (i === 0 ? n : n.toFixed(1)) + " " + units[i];
	}

	function humanDate(iso) {
		if (!iso) return "";
		var d = new Date(iso);
		if (isNaN(d.getTime())) return iso;
		return d.toISOString().slice(0, 10);
	}

	// A device matches the query if EVERY whitespace-separated token in the
	// query appears somewhere in its searchable text -- lets "mt6000 test"
	// or "archer c7" work without requiring an exact phrase.
	function matchesQuery(device, query) {
		if (!query) return true;
		var haystack = [
			device.board_name, device.display_name, device.target,
			(device.aliases || []).join(" ")
		].join(" ").toLowerCase();
		var tokens = query.toLowerCase().split(/\s+/).filter(Boolean);
		return tokens.every(function (t) { return haystack.indexOf(t) !== -1; });
	}

	function releasesForChannel(device, channel) {
		if (channel === "all") return device.releases;
		return device.releases.filter(function (r) { return r.channel === channel; });
	}

	function copyToClipboard(text, onDone) {
		if (navigator.clipboard && navigator.clipboard.writeText) {
			navigator.clipboard.writeText(text).then(onDone, onDone);
		} else {
			onDone();
		}
	}

	function renderImageRow(img) {
		var row = el("div", "image-row");
		var a = el("a", null, img.type + " (" + img.filename + ")");
		a.href = img.url;
		row.appendChild(a);
		row.appendChild(el("span", "size", humanSize(img.size)));
		var sha = el("span", "sha", "sha256: " + img.sha256.slice(0, 12) + "…");
		sha.title = "Click to copy full sha256: " + img.sha256;
		sha.addEventListener("click", function () {
			var original = sha.textContent;
			copyToClipboard(img.sha256, function () {
				sha.textContent = "copied!";
				setTimeout(function () { sha.textContent = original; }, 1200);
			});
		});
		row.appendChild(sha);
		return row;
	}

	function renderRelease(rel) {
		var wrap = el("div", "release");
		var head = el("div", "release-head");
		head.appendChild(el("span", "version", rel.version));
		head.appendChild(el("span", "chip", rel.channel));
		head.appendChild(el("span", "date", humanDate(rel.date)));
		wrap.appendChild(head);
		var images = el("div", "images");
		rel.images.forEach(function (img) { images.appendChild(renderImageRow(img)); });
		wrap.appendChild(images);
		return wrap;
	}

	function renderDevice(device, channel) {
		var releases = releasesForChannel(device, channel);
		if (releases.length === 0) return null;

		var card = el("div", "device" + (device.eol ? " eol" : ""));
		var head = el("div", "device-head");
		var left = el("div");
		left.appendChild(el("div", "device-name", device.display_name));
		left.appendChild(el("div", "device-sub", device.board_name + "  ·  " + device.target));
		head.appendChild(left);

		if (device.eol) {
			head.appendChild(el("span", "badge", "Final: " + (device.final_version || "?")));
		} else if (!device.known_device) {
			head.appendChild(el("span", "unknown-note", "no device metadata yet"));
		}
		card.appendChild(head);

		if (device.note) card.appendChild(el("p", "note", device.note));

		var relWrap = el("div", "releases");
		releases.forEach(function (r) { relWrap.appendChild(renderRelease(r)); });
		card.appendChild(relWrap);

		head.addEventListener("click", function () {
			card.classList.toggle("open");
		});

		return card;
	}

	function render() {
		var results = $("#results");
		var empty = $("#empty");
		results.innerHTML = "";

		var devices = state.data.entries.filter(function (d) {
			return matchesQuery(d, state.query) && releasesForChannel(d, state.channel).length > 0;
		});

		if (devices.length === 0) {
			empty.style.display = "block";
			return;
		}
		empty.style.display = "none";

		// Auto-expand when the search has narrowed to a single device -- the
		// common "I typed my exact model" case shouldn't need an extra click.
		var autoOpen = devices.length === 1;

		devices.forEach(function (d) {
			var card = renderDevice(d, state.channel);
			if (!card) return;
			if (autoOpen) card.classList.add("open");
			results.appendChild(card);
		});
	}

	// --- backup-tarball identifier (RFC #62 Rung 2, logic in identify.js) ---

	var ROUTING_TEXT = {
		"direct": "Your firmware era can flash the current image directly through System → Update.",
		"direct-legacy-name": "Your firmware era can flash the current image directly through System → Update (the image still carries this board’s legacy name for compatibility).",
		"manual-factory": "Your firmware era needs the manual factory-image path — do not use a sysupgrade image; follow the device’s factory flashing instructions."
	};

	function renderIdentifyResult(res) {
		var box = $("#identify-result");
		box.innerHTML = "";
		box.hidden = false;

		if (!res.ok) {
			box.appendChild(el("p", "identify-error", res.reason));
			return;
		}

		var pathsLine = el("p", "identify-paths",
			"Radios found in the backup: " + (res.radioCount || 0) +
			(res.wifiPaths.length ? " (" + res.wifiPaths.join(", ") + ")" : ""));
		box.appendChild(pathsLine);

		if (res.era) {
			box.appendChild(el("p", "identify-era",
				"Firmware era: " + res.era.label + " — " + res.era.detail + "."));
		}

		if (res.candidates.length === 0) {
			var none = el("p", "identify-error",
				"No known device fingerprint matches these radio paths. Search manually above — and please open an issue on gargoyle-firmware quoting the paths shown, so this board can be fingerprinted.");
			box.appendChild(none);
			return;
		}

		var exact = res.candidates.filter(function (c) { return c.score === 1; });
		var intro = exact.length === 1
			? "Best match:"
			: "Radio paths are shared within a hardware family — likely candidates (confirm against the label on your router):";
		box.appendChild(el("p", null, intro));

		var list = el("div", "identify-candidates");
		res.candidates.forEach(function (c) {
			var row = el("button", "candidate");
			row.type = "button";
			row.appendChild(el("span", "candidate-name", c.device.display_name));
			row.appendChild(el("span", "candidate-score", Math.round(c.score * 100) + "% fingerprint match"));
			var advice = GargoyleIdentify.routingAdvice(c.device, res.era);
			if (advice && ROUTING_TEXT[advice]) {
				row.appendChild(el("span", "candidate-advice", ROUTING_TEXT[advice]));
			}
			row.addEventListener("click", function () {
				state.query = c.device.board_name;
				$("#search").value = state.query;
				render();
			});
			list.appendChild(row);
		});
		box.appendChild(list);
	}

	function handleBackupFile(file) {
		var box = $("#identify-result");
		box.hidden = false;
		box.innerHTML = "";
		box.appendChild(el("p", null, "Reading " + file.name + "…"));
		GargoyleIdentify.analyze(file, state.data.entries)
			.then(renderIdentifyResult)
			.catch(function (err) {
				box.innerHTML = "";
				box.appendChild(el("p", "identify-error", "Could not read that file: " + err.message));
			});
	}

	function wireIdentify() {
		var dz = $("#dropzone");
		["dragover", "dragenter"].forEach(function (ev) {
			dz.addEventListener(ev, function (e) { e.preventDefault(); dz.classList.add("drag"); });
		});
		["dragleave", "drop"].forEach(function (ev) {
			dz.addEventListener(ev, function (e) { e.preventDefault(); dz.classList.remove("drag"); });
		});
		dz.addEventListener("drop", function (e) {
			if (e.dataTransfer.files && e.dataTransfer.files.length) {
				handleBackupFile(e.dataTransfer.files[0]);
			}
		});
		$("#backupfile").addEventListener("change", function (e) {
			if (e.target.files && e.target.files.length) {
				handleBackupFile(e.target.files[0]);
			}
		});
	}

	function wireControls() {
		$("#search").addEventListener("input", function (e) {
			state.query = e.target.value;
			render();
		});

		var buttons = document.querySelectorAll(".channel-toggle button");
		buttons.forEach(function (btn) {
			btn.addEventListener("click", function () {
				buttons.forEach(function (b) { b.setAttribute("aria-pressed", "false"); });
				btn.setAttribute("aria-pressed", "true");
				state.channel = btn.dataset.channel;
				render();
			});
		});
	}

	function boot() {
		fetch("./index.json", { cache: "no-store" })
			.then(function (r) {
				if (!r.ok) throw new Error("index.json: HTTP " + r.status);
				return r.json();
			})
			.then(function (data) {
				state.data = data;
				var meta = $("#meta");
				var deviceCount = data.entries.length;
				var releaseCount = data.entries.reduce(function (n, d) { return n + d.releases.length; }, 0);
				meta.textContent = deviceCount + " device" + (deviceCount === 1 ? "" : "s") +
					", " + releaseCount + " release" + (releaseCount === 1 ? "" : "s") +
					" · index generated " + humanDate(data.generated);
				wireControls();
				wireIdentify();
				render();
			})
			.catch(function (err) {
				$("#meta").textContent = "Could not load index.json: " + err.message;
			});
	}

	document.addEventListener("DOMContentLoaded", boot);
})();
