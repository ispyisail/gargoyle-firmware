
# parse-control.awk -- parse a Debian/opkg-format control file into
# unambiguous key/value records for jq to reassemble into JSON.
#
# Real control-file values (Description in particular) legitimately contain
# embedded newlines via the continuation-line convention, so a naive
# "\t"-separated, "\n"-terminated record format collides with that: a
# multi-line value gets sliced into bogus extra records. Using ASCII Unit
# Separator (0x1F) between key and value, and Record Separator (0x1E)
# between records, sidesteps this -- neither character appears in real
# control-file text, so embedded newlines inside a value are always safe.
#
# Field-separator rule (verified against real Gargoyle-built .ipk control
# files, cross-checked against the real Packages index opkg's own build
# produces from them): "Key:" is followed by exactly ONE mandatory
# separator space; any further leading whitespace is literal value content
# (some Description lines carry a real double space). Continuation lines
# (leading space/tab) have exactly one leading whitespace char stripped the
# same way. This script only PARSES using that rule; make-feed.sh's jq
# renderer re-applies the matching write-side convention.
BEGIN {
	key = ""; val = ""
	US = sprintf("%c", 31)
	RS_ = sprintf("%c", 30)
}
function flush() {
	if (key != "") {
		printf "%s%s%s%s", key, US, val, RS_
	}
}
/^[A-Za-z][A-Za-z0-9-]*:/ {
	flush()
	line = $0
	colon = index(line, ":")
	key = substr(line, 1, colon - 1)
	val = substr(line, colon + 1)
	sub(/^[ \t]/, "", val)
	next
}
/^[ \t]/ {
	if (key != "") {
		line = $0
		sub(/^[ \t]/, "", line)
		val = val "\n" line
	}
	next
}
END { flush() }
