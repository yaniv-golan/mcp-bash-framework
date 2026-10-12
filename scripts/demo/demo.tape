# README demo. Re-record from the repository root (needs vhs and docker):
#   vhs scripts/demo/demo.tape
# The commands run in a throwaway Alpine container (scripts/demo/init.sh), so
# the recording shows generic paths, not the recording machine's.
Output "assets/mcp-bash-demo.gif"
Set Shell "bash"
Set FontSize 16
Set Width 1100
Set Height 620
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set WaitTimeout 30s
Set WaitPattern /^\$$/
Hide
Type "docker run -it --rm -v $PWD:/opt/mcp-bash:ro -v $PWD/scripts/demo/init.sh:/init.sh:ro alpine:3.20 sh /init.sh"
Enter
Sleep 6s
Type "clear"
Enter
Sleep 500ms
Show
Type "mcp-bash new weather-server && cd weather-server"
Enter
Wait
Sleep 1.5s
Type "mcp-bash scaffold tool forecast"
Enter
Wait
Sleep 1.5s
Type `mcp-bash run-tool hello --allow-self --args '{"name":"World"}' | jq .structuredContent`
Enter
Wait
Sleep 2.5s
Type "mcp-bash config --client claude-desktop"
Enter
Wait
Sleep 4s
Hide
Type "exit"
Enter
