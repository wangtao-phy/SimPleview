#!/bin/bash
cat << 'LLDB_CMDS' > lldb_script.txt
run
bt
quit
LLDB_CMDS
lldb -s lldb_script.txt /Users/wangtao/Library/Developer/Xcode/DerivedData/SimPleview-fzfnyuhoqflxhudsqyenonchrfqu/Build/Products/Debug/SimPleview.app/Contents/MacOS/SimPleview
