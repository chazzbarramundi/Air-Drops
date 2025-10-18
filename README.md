# Air-Drops
DCS mission script that allows Air Drops to be called in from the radio menu.

This script includes the spawning of c130's, which will carry 2 weapons platforms for deployment. It has 3 variations, Tank, Apc and Hummer. Once the radio command is issued it will give you a code so you can create a mission map marker in the f10 menu with that code. If you would like to troubleshoot in the lua script you can turn debuging on which will output messages that will help you troubleshoot.

# Instructions
1. Open the example mission file `Air Drop.miz` in the mission editor.
3. Click the Set Rules for trigger icon on the left hand nav menu. (3 Down from the text "MIS")
4. Note the ONCE trigger is set. Click on it.
5. Note the Time More is set to trigger on load.
6. Click the DO SCRIPT FILE and make sure it is linked to the Air `Air Drop.lua` script.
7. Load the mission, then access the spawning through the Radio Menu Commands.
8. Place the map marker with the correct code
9. Watch the c130's spawn and deliver your drop
10. Enjoy.