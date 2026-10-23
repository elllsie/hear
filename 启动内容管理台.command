#!/bin/zsh
cd -- "${0:A:h}" || exit 1
if [[ ! -x backend/.venv/bin/python ]]; then
  print '缺少 backend/.venv/bin/python，请先按 backend/README.md 配置 Python 环境。'
  read '?按回车关闭…'
  exit 1
fi
exec backend/.venv/bin/python -B -m backend.local_admin.server --open "$@"
