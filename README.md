![DCS Airdrop Script for Eagle Dynamics Digital Combat Simulator.](/assets/images/head.png)

# DCS Air Drops for the C130j
This is a DCS mission .lua script that allows c130 Air Drops to be called in from the radio menu. It also allows the player to drop CDS crates and use map markers to "manufacture" ground vehicles from dropped CDS supply crates.

This script includes the spawning of c130's, which will carry 2 weapons platforms for deployment. It has 3 variations, Tank, Apc and Hummer. Once the radio command is issued it will give you a map marker code so you can create a mission map marker in the f10 menu with that code. 

If you would like to troubleshoot in the lua script you can turn debuging on which will output messages.

# Instructions

## Setup
1. Place the `Air Drop.lua` script in your mission's MISSION SCRIPTS folder
2. Load the script in the mission editor using the "Do Script" action

Alternatively:
1. Open the example mission file `Air Drop.miz` in the mission editor
2. Click the Set Rules for trigger icon on the left hand nav menu (3 Down from the text "MIS")
3. Note the ONCE trigger is set. Click on it
4. Note the Time More is set to trigger on load
5. Click the DO SCRIPT FILE and make sure it is linked to the `Air Drop.lua` script

## Usage

### Radio Menu Air Drops
- Use the radio menu to call in drops (costs CMD points if Player Tracker system is loaded)
- Place map markers named `dp-alpha`, `dp-bravo`, etc. for drop zones (these are generated dynamically)

### Manual C-130J Drops
- Spawn cargo containers using the C-130J mod (or any static object with the correct name pattern) 
- Fly and drop them from the C-130J
- Use "make tank", "make apc", or "make humvee" map markers to spawn vehicles from nearby landed crates

### CMD Point Costs (if Player Tracker available)
- 2 units (1 C-130): 20 CMD points
- 4 units (2 C-130s): 40 CMD points  
- 6 units (3 C-130s): 60 CMD points
- 8 units (4 C-130s): 80 CMD points

### Manufacturing Requirements
Each spawn requires 2 CDS crates. If you are wanting to build a FARP use 4 CDS containers and the map command `make farp`.

![DCS Airdrop Script for Eagle Dynamics Digital Combat Simulator.](/assets/images/cds.png)
![DCS Airdrop Script for Eagle Dynamics Digital Combat Simulator.](/assets/images/cds2.png)
![DCS Airdrop Script for Eagle Dynamics Digital Combat Simulator.](/assets/images/farp.png)
![DCS Airdrop Script for Eagle Dynamics Digital Combat Simulator.](/assets/images/farp1.png)