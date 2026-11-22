# Sourced by the build and validation scripts after they set ROOT.
XCCONFIG_REL="Configuration/AppIdentity.xcconfig"
XCCONFIG="$ROOT/$XCCONFIG_REL"

# The identity check also needs the raw template before Xcode target overrides.
xcconfig_value() {
  awk -v key="$1" -v mode="${2:-expanded}" '
    function trim(text) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
      return text
    }
    function expand(name,    rest, result, ref) {
      if (name in active) {
        printf "error: circular xcconfig reference to %s in %s\n", name, FILENAME > "/dev/stderr"
        exit 1
      }
      active[name] = 1
      rest = values[name]
      while (match(rest, /\$\([A-Za-z_][A-Za-z0-9_]*\)/)) {
        ref = substr(rest, RSTART + 2, RLENGTH - 3)
        result = result substr(rest, 1, RSTART - 1)
        rest = substr(rest, RSTART + RLENGTH)
        result = result (ref in values ? expand(ref) : "$(" ref ")")
      }
      delete active[name]
      return result rest
    }
    /^[[:space:]]*#/ { next }
    {
      sub(/\/\/.*/, "")
      eq = index($0, "=")
      if (eq && (name = trim(substr($0, 1, eq - 1))) != "")
        values[name] = trim(substr($0, eq + 1))
    }
    END { print (mode == "raw" ? values[key] : expand(key)) }
  ' "$XCCONFIG"
}
