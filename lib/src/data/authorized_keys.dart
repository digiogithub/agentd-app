// Installs the app's public key in ~/.ssh/authorized_keys (password
// bootstrap). The key line comes on stdin, so nothing is quoted into the
// command and nothing secret is in it anyway (a public key).

/// POSIX sh script: reads one public key line on stdin, creates `~/.ssh`
/// (0700) and `authorized_keys` (0600) when missing, fixes their modes, and
/// appends the line only when its key blob is not there yet. Prints `added`
/// or `present`.
const installAuthorizedKeyScript = r'''
umask 077
IFS= read -r k || [ -n "$k" ] || { echo "no key on stdin" >&2; exit 2; }
case $k in ssh-*|ecdsa-*|sk-*) ;; *) echo "not a public key line" >&2; exit 2 ;; esac
b=$(printf '%s\n' "$k" | awk '{print $2}')
[ -n "$b" ] || { echo "no key blob" >&2; exit 2; }
d=$HOME/.ssh
f=$d/authorized_keys
mkdir -p "$d" && chmod 700 "$d" || exit 1
[ -f "$f" ] || : > "$f" || exit 1
chmod 600 "$f" || exit 1
if grep -qF -- "$b" "$f"; then echo present; exit 0; fi
if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\n' >> "$f"; fi
printf '%s\n' "$k" >> "$f" && echo added
''';
