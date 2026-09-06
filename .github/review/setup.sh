#!/bin/sh
# Loaded from the trusted base by Review Loop; runs before repository checkout.
set -eu

rl_mode=${1:-install}
case "$rl_mode" in
  --downloads) rl_arch=${2:?specify amd64 or arm64} ;;
  install)
    . /etc/os-release
    test "$ID" = ubuntu || { echo 'Fountain verification requires Ubuntu' >&2; exit 1; }
    case "$VERSION_ID" in 24.04|26.04) ;; *) echo 'Unsupported Ubuntu verification image' >&2; exit 1 ;; esac
    case "$(uname -m)" in x86_64) rl_arch=amd64 ;; aarch64) rl_arch=arm64 ;; *) echo 'Unsupported verification architecture' >&2; exit 1 ;; esac
    ;;
  *) echo 'usage: setup.sh [--downloads amd64|arm64]' >&2; exit 1 ;;
esac

case "$rl_arch" in
  amd64)
    rl_node_arch=x64
    rl_otp_sha=e2511c494d40ed7bd92eaa1eddc8fa11a0828c8a6c1e6b3a55d5e16539455902
    rl_node_sha=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
    rl_go_sha=aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235
    ;;
  arm64)
    rl_node_arch=arm64
    rl_otp_sha=8d61124bbe1023cebf94dc13a0032141fd1bcc4753e3ad4ab3679a4a56ec190a
    rl_node_sha=5f4ddab610c1ab2016b3c227cebdbf6d9495161487e4739c7b90090595f465f7
    rl_go_sha=bd03b743eb6eb4193ea3c3fd3956546bf0e3ca5b7076c8226334afe6b75704cd
    ;;
  *) echo 'Unsupported verification architecture' >&2; exit 1 ;;
esac

# One inventory drives both installation and the read-only download audit.
# Fields: filename, digest algorithm, expected digest, immutable-version URL.
downloads() {
  cat <<EOF
otp.tar.gz sha256 $rl_otp_sha https://builds.hex.pm/builds/otp/$rl_arch/ubuntu-24.04/OTP-28.3.tar.gz
elixir.zip sha256 ab46737d9e3bf18cdef4db154ed20f59b86043be4494a88caab966c92d084a07 https://builds.hex.pm/builds/elixir/v1.19.2-otp-28.zip
node.tar.xz sha256 $rl_node_sha https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-$rl_node_arch.tar.xz
go.tar.gz sha256 $rl_go_sha https://go.dev/dl/go1.26.0.linux-$rl_arch.tar.gz
hex.ez sha512 b97d99a4d137bfa7fbd2c70e141f345e911d45ad541c2e8f8cd500edb0d8d682eb52463a3ccd85cfc18e141b847d4f6a03534e2a0dbd798014c1ed641572cc8f https://builds.hex.pm/installs/1.19.0/hex-2.5.1-otp-28.ez
rebar3 sha512 992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24 https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28
EOF
}
if [ "$rl_mode" = --downloads ]; then downloads; exit 0; fi

root_cmd() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }
rl_tools=/opt/review-loop-tools
test ! -e "$rl_tools" || { echo 'Setup requires a fresh verification machine' >&2; exit 1; }
root_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -qq
root_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  ca-certificates curl git unzip xz-utils build-essential cmake pkg-config perl \
  libssl-dev libncurses-dev python3 libpq-dev postgresql postgresql-client
root_cmd install -d -o "$(id -u)" -g "$(id -g)" "$rl_tools"
rl_tmp=$(mktemp -d)
trap 'rm -rf "$rl_tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
downloads > "$rl_tmp/downloads"
while read -r rl_file rl_algorithm rl_digest rl_url; do
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 --retry 2 "$rl_url" -o "$rl_tmp/$rl_file"
  printf '%s  %s\n' "$rl_digest" "$rl_tmp/$rl_file" | "${rl_algorithm}sum" --check --status
done < "$rl_tmp/downloads"

mkdir "$rl_tools/otp" "$rl_tools/elixir" "$rl_tools/node" "$rl_tools/mix"
tar -xzf "$rl_tmp/otp.tar.gz" --strip-components=1 -C "$rl_tools/otp"
(cd "$rl_tools/otp" && ./Install -minimal "$rl_tools/otp")
unzip -q "$rl_tmp/elixir.zip" -d "$rl_tools/elixir"
tar -xJf "$rl_tmp/node.tar.xz" --strip-components=1 -C "$rl_tools/node"
tar -xzf "$rl_tmp/go.tar.gz" -C "$rl_tools"

# A stable wrapper carries tool paths and test-only configuration across the
# separate shells used for verification commands. No host credentials enter it.
cat > "$rl_tools/rl-env" <<'EOF'
#!/bin/sh
export PATH=/opt/review-loop-tools/otp/bin:/opt/review-loop-tools/elixir/bin:/opt/review-loop-tools/node/bin:/opt/review-loop-tools/go/bin:/usr/local/bin:/usr/bin:/bin
export MIX_HOME=/opt/review-loop-tools/mix MIX_ENV=test
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/fountain_test
export ERL_FLAGS='+S 2:2'
export LANG=C.UTF-8 LC_ALL=C.UTF-8
exec "$@"
EOF
chmod 755 "$rl_tools/rl-env"
root_cmd ln -s "$rl_tools/rl-env" /usr/local/bin/rl-env
rl-env mix archive.install "$rl_tmp/hex.ez" --force
rl-env mix local.rebar rebar3 "$rl_tmp/rebar3" --force
rl-env mix hex.info
rl-env elixir -e 'unless System.version() == "1.19.2" and System.otp_release() == "28", do: raise("wrong BEAM toolchain")'
test "$(cat "$rl_tools/otp/releases/28/OTP_VERSION")" = 28.3
test "$(rl-env node --version)" = v24.20.0
rl-env go version | /usr/bin/grep -q '^go version go1.26.0 linux/'

# Use the packaged postgres account: initdb refuses root, including when the
# provider starts this setup as root. Use this Ubuntu image's packaged major;
# GitHub CI independently verifies PostgreSQL 16. Stop the newly installed
# default cluster before reserving the local test port on this fresh worker.
rl_pg_bin=$(pg_config --bindir)
rl_pg_major=$("$rl_pg_bin/postgres" --version | awk '{split($3,v,"."); print v[1]}')
case "$rl_pg_major" in 16|18) ;; *) echo 'Unsupported PostgreSQL verification version' >&2; exit 1 ;; esac
root_cmd pg_ctlcluster "$rl_pg_major" main stop 2>/dev/null || true
rl_pg=/var/lib/postgresql/review-loop
test ! -e "$rl_pg" || { echo 'Test database directory already exists' >&2; exit 1; }
root_cmd install -d -o postgres -g postgres -m 700 "$rl_pg"
printf 'postgres\n' | root_cmd tee "$rl_pg/password" >/dev/null
root_cmd chown postgres:postgres "$rl_pg/password"
root_cmd chmod 600 "$rl_pg/password"
root_cmd runuser -u postgres -- "$rl_pg_bin/initdb" -D "$rl_pg/data" \
  --username=postgres --pwfile="$rl_pg/password" --auth-local=trust --auth-host=scram-sha-256 \
  --encoding=UTF8 --locale=C.UTF-8 >/dev/null
root_cmd rm "$rl_pg/password"
root_cmd runuser -u postgres -- "$rl_pg_bin/pg_ctl" -D "$rl_pg/data" \
  -l "$rl_pg/server.log" -o "-h 127.0.0.1 -p 5432 -k $rl_pg" -w start
rl-env sh -c 'PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT version()"'
echo "Fountain verification toolchains and local PostgreSQL $rl_pg_major are ready."
