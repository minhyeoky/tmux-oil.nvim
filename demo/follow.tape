# vhs demo/follow.tape  — records demo/follow.gif (follow_cursor = true)
Output demo/follow.gif

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

# the cursor opens on the current window; moving it selects the window behind the popup
Sleep 1s
Ctrl+a
Type "s"
Sleep 2s
Type "j"
Sleep 1.2s
Type "j"
Sleep 1.2s
Type "j"
Sleep 1.2s

# another session
Type "G"
Sleep 1.5s
Type "k"
Sleep 1.5s

# q puts everything back
Type "q"
Sleep 2s

# Enter keeps the selection
Ctrl+a
Type "s"
Sleep 1.5s
Type "jj"
Sleep 1.2s
Enter
Sleep 2.5s

Hide
Ctrl+a
Type "d"
Sleep 300ms
Type "tmux -L tmux-oil-demo kill-server"
Enter
