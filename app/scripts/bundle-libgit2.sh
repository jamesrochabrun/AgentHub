#!/bin/sh
set -euo pipefail

if [ "${AGENTHUB_BUNDLE_LIBGIT2:-1}" = "0" ]; then
  exit 0
fi

brew_prefix="${HOMEBREW_PREFIX:-}"
if [ -z "${brew_prefix}" ]; then
  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix)"
  elif [ -d /opt/homebrew ]; then
    brew_prefix=/opt/homebrew
  elif [ -d /usr/local ]; then
    brew_prefix=/usr/local
  fi
fi

if [ -z "${brew_prefix}" ]; then
  echo "error: Homebrew prefix not found. Install official libgit2 with: brew install libgit2"
  exit 1
fi

libgit2="${brew_prefix}/opt/libgit2/lib/libgit2.1.9.dylib"
libssh2="${brew_prefix}/opt/libssh2/lib/libssh2.1.dylib"
libssl="${brew_prefix}/opt/openssl@3/lib/libssl.3.dylib"
libcrypto="${brew_prefix}/opt/openssl@3/lib/libcrypto.3.dylib"

for lib in "${libgit2}" "${libssh2}" "${libssl}" "${libcrypto}"; do
  if [ ! -f "${lib}" ]; then
    echo "error: required libgit2 runtime dependency missing: ${lib}"
    echo "Install dependencies with: brew install libgit2 libssh2 openssl@3"
    exit 1
  fi
done

libllhttp="$(otool -L "${libgit2}" | awk '$1 ~ /libllhttp/ { print $1; exit }')"
if [ -n "${libllhttp}" ]; then
  if [ ! -f "${libllhttp}" ]; then
    libllhttp_candidate="${brew_prefix}/opt/llhttp/lib/$(basename "${libllhttp}")"
    if [ -f "${libllhttp_candidate}" ]; then
      libllhttp="${libllhttp_candidate}"
    else
      echo "error: required libgit2 runtime dependency missing: ${libllhttp}"
      echo "Install dependencies with: brew install libgit2 libssh2 openssl@3 llhttp"
      exit 1
    fi
  fi
  libllhttp_name="$(basename "${libllhttp}")"
fi

frameworks_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${frameworks_dir}"

copy_lib() {
  src="$1"
  name="$2"
  dst="${frameworks_dir}/${name}"
  cp -fL "${src}" "${dst}"
  chmod u+w "${dst}"
}

copy_lib "${libgit2}" "libgit2.1.9.dylib"
copy_lib "${libssh2}" "libssh2.1.dylib"
copy_lib "${libssl}" "libssl.3.dylib"
copy_lib "${libcrypto}" "libcrypto.3.dylib"
if [ -n "${libllhttp}" ]; then
  copy_lib "${libllhttp}" "${libllhttp_name}"
fi

rewrite_dependency() {
  target="$1"
  match="$2"
  replacement="$3"

  if [ ! -f "${target}" ]; then
    return 0
  fi

  otool -L "${target}" | awk -v needle="${match}" '$1 ~ needle { print $1 }' | while read -r old_path; do
    case "${old_path}" in
      @rpath/*|/System/*|/usr/lib/*)
        continue
        ;;
    esac
    install_name_tool -change "${old_path}" "${replacement}" "${target}"
  done
}

install_name_tool -id "@rpath/libgit2.1.9.dylib" "${frameworks_dir}/libgit2.1.9.dylib"
install_name_tool -id "@rpath/libssh2.1.dylib" "${frameworks_dir}/libssh2.1.dylib"
install_name_tool -id "@rpath/libssl.3.dylib" "${frameworks_dir}/libssl.3.dylib"
install_name_tool -id "@rpath/libcrypto.3.dylib" "${frameworks_dir}/libcrypto.3.dylib"
if [ -n "${libllhttp}" ]; then
  install_name_tool -id "@rpath/${libllhttp_name}" "${frameworks_dir}/${libllhttp_name}"
fi

if [ -n "${libllhttp}" ]; then
  rewrite_dependency "${frameworks_dir}/libgit2.1.9.dylib" "libllhttp" "@rpath/${libllhttp_name}"
fi
rewrite_dependency "${frameworks_dir}/libgit2.1.9.dylib" "libssh2" "@rpath/libssh2.1.dylib"
rewrite_dependency "${frameworks_dir}/libssh2.1.dylib" "libssl" "@rpath/libssl.3.dylib"
rewrite_dependency "${frameworks_dir}/libssh2.1.dylib" "libcrypto" "@rpath/libcrypto.3.dylib"
rewrite_dependency "${frameworks_dir}/libssl.3.dylib" "libcrypto" "@rpath/libcrypto.3.dylib"

macos_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/MacOS"
for binary in "${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}" "${macos_dir}/${PRODUCT_NAME}.debug.dylib"; do
  rewrite_dependency "${binary}" "libgit2" "@rpath/libgit2.1.9.dylib"
done

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [ -z "${signing_identity}" ]; then
    signing_identity="${CODE_SIGN_IDENTITY:-}"
  fi
  if [ -z "${signing_identity}" ]; then
    signing_identity="-"
  fi

  for lib in \
    "${frameworks_dir}/libcrypto.3.dylib" \
    "${frameworks_dir}/libssl.3.dylib" \
    "${frameworks_dir}/${libllhttp_name:-libllhttp.dylib}" \
    "${frameworks_dir}/libssh2.1.dylib" \
    "${frameworks_dir}/libgit2.1.9.dylib"; do
    if [ ! -f "${lib}" ]; then
      continue
    fi
    codesign --force --sign "${signing_identity}" --timestamp=none "${lib}"
  done
fi
