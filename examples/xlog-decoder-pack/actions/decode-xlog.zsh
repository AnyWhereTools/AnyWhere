#!/bin/zsh
# AnyWhere passes selected files through "$@". Decode alongside each original.
emulate -L zsh
setopt pipefail
umask 077

fail() { print -ru2 -- "$1"; exit 1; }
decoder="${0:A:h:h}/bin/xlog-decoder"
[[ -x "$decoder" ]] || fail "找不到包内解码器或没有执行权限，请检查 bin/xlog-decoder。"
(( $# > 0 )) || fail "请选择一个或多个 .xlog 文件。"

# Validate the whole selection before prompting or writing any output.
for input in "$@"; do
  [[ -f "$input" && -r "$input" && "${input:e:l}" == xlog ]] ||
    fail "请选择可读取的 .xlog 文件：${input:t}"
done

private_key="${ANYWHERE_CONFIG_PRIVATE_KEY-}"
key_args=()
if [[ -n "$private_key" ]]; then
  [[ ${#private_key} -eq 64 && "$private_key" != *[^0-9a-fA-F]* ]] ||
    fail "私钥格式不正确：请在此动作的插件配置中填写 64 位十六进制私钥。"
  key_args=(-p "$private_key")
fi

temp_dir=""
trap '[[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ok=0
failed=0
for input in "$@"; do
  input="${input:a}"
  temp_dir=$(mktemp -d "${input:h}/.anywhere-xlog.XXXXXX") ||
    fail "无法在日志目录创建临时文件：${input:h}"
  # The decoder may return 0 even for invalid input; require nonempty output too.
  # Keep its raw diagnostics out of AnyWhere's execution history.
  if "$decoder" decode -i "$input" -o "$temp_dir/output.log" "${key_args[@]}" >/dev/null 2>&1 &&
      [[ -s "$temp_dir/output.log" ]]; then
    output="${input:r}.log"
    n=2
    while [[ -e "$output" || -L "$output" ]]; do
      output="${input:r} ${n}.log"
      (( n++ ))
    done
    if mv -n -- "$temp_dir/output.log" "$output" && [[ ! -e "$temp_dir/output.log" ]]; then
      (( ok++ ))
    else
      print -ru2 -- "无法保存日志：${input:t}"
      (( failed++ ))
    fi
  else
    print -ru2 -- "解码失败或输出为空：${input:t}（请检查日志格式和此动作的插件配置中的私钥）"
    (( failed++ ))
  fi
  rm -rf -- "$temp_dir"
  temp_dir=""
done
unset private_key key_args

if (( failed > 0 )); then
  fail "成功 ${ok} 个，失败 ${failed} 个；已成功的日志保留在原目录。"
fi
print -r -- "已解码 ${ok} 个 Xlog，日志已保存到原目录。"
