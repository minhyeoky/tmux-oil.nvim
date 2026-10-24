# vhs demo/demo.tape  — records demo/demo.gif + demo.mp4
Output demo/demo.gif
Output demo/demo.mp4
Output demo/frames/

Set Shell zsh
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 17
Set Width 1200
Set Height 700
Set Padding 20
Set Theme "GruvboxDark"
Set WindowBar Colorful
Set WindowBarSize 36
Set TypingSpeed 60ms
Set CursorBlink false

Hide
Type "export TMUX_OIL_ROOT=$PWD; export PATH=$(sh demo/setup.sh):$PATH; clear"
Enter
Sleep 1s
Type "tmux -L tmux-oil-demo attach -t dev"
Enter
Sleep 1.5s
Show

Sleep 1.5s
Ctrl+a
Type "s"
Sleep 2.5s

# a new window under the current one
Type "o"
Sleep 300ms
Type "tests"
Sleep 300ms
Escape
Sleep 1.2s

# rename the unnamed window
Type "jj"
Sleep 600ms
Type "cc"
Sleep 300ms
Type "release-notes"
Sleep 300ms
Escape
Sleep 1.2s

# move "web" to the bottom
Type "k"
Sleep 400ms
Type "dd"
Sleep 500ms
Type "jp"
Sleep 1.2s

# send "docs" to the infra session
Type "k"
Sleep 400ms
Type "dd"
Sleep 500ms
Type "G"
Sleep 500ms
Type "p"
Sleep 1.5s

# close "logs"
Type "k"
Sleep 400ms
Type "dd"
Sleep 1.5s

# apply
Type ":w"
Sleep 400ms
Enter
Sleep 3.5s
Type "y"
Sleep 2.5s

# jump to the renamed window: same window, still running
Type "gg"
Type "jjj"
Sleep 800ms
Enter
Sleep 3s

Hide
Ctrl+a
Type "d"
Sleep 300ms
Type "tmux -L tmux-oil-demo kill-server"
Enter
