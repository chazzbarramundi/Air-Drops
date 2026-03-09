# Air Drop Script Changelog

## v0.4 - SAM Deployment System
**Release Date:** March 9, 2026

### Major New Features
- **Support Truck Deployment**: Added the support truck to the spawn list
- **SAM Site Deployment**: Added Surface-to-Air Missile (SAM) spawning capability via make commands
  - **Short Range SAM (SRSAM)**: NASAMS system with Command Post, Radar, and Launcher units
  - **Long Range SAM (LRSAM)**: Hawk system with CWAR, multiple Launchers, PCP, SR, and TR units
- **Multi-Unit Group Spawning**: SAM sites spawn as complete groups with multiple coordinated units
- **Randomized Positioning**: Units positioned realistically around map markers with configurable spacing and randomization

### Enhanced Make Command System
- **New Map Marker Commands**:
  - `make srsam` / `make shortrange` - Spawns 4-unit NASAMS system  
  - `make lrsam` / `make longrange` - Spawns 7-unit Hawk system
- **Material Requirements**: SAM sites require 5 landed containers each for realistic resource consumption

### SAM Configuration System
- **SAM_UNITS Configuration**: Comprehensive unit definitions with skill levels and coalition support
- **SAM_DEPLOYMENT Settings**: Configurable positioning parameters
  - `UNIT_SPACING`: Base distance between SAM units (default: 30m)
  - `MAX_RANDOM_OFFSET`: Maximum position randomization (default: 15m)  
  - `ENABLE_RANDOM_HEADING`: Random unit facing directions
  - `ENABLE_POSITION_RANDOMIZATION`: Toggle randomized positioning

### Technical Improvements
- **Enhanced Marker Parsing**: Robust text parsing for SAM commands with multiple alias support
- **Circular Unit Distribution**: Smart positioning algorithm distributes SAM units in realistic formations
- **Comprehensive Debug Logging**: Detailed SAM spawning information with configuration validation
- **Error Handling**: Graceful fallback when SAM configurations are missing or invalid

---

## v0.3 - Performance and Manufacturing Update
**Release Date:** March 1, 2026

### New Features
- **Container Tracking System**: Added comprehensive tracking for C-130J containers with airborne/landed status detection
- **Manufacturing System**: Implemented "make" command functionality via map markers
  - Place markers with text "make tank", "make apc", or "make humvee" to manufacture vehicles
  - Requires 2 landed containers per vehicle for realistic resource consumption
  - Automatically consumes closest containers within 500m radius
- **Production Mode**: Added configurable production mode for optimized performance in live missions

### Performance Improvements
- **Consolidated Monitoring**: Reduced from 4 separate timer callbacks to 2 (~60% efficiency gain)
- **Configurable Scan Frequencies**: Added `scan_frequency` and `monitor_frequency` settings for performance tuning
- **Optimized Container Scanning**: Single-pass scanning and monitoring instead of multiple iterations
- **Reduced Debug Overhead**: Production mode dramatically reduces debug output while preserving critical messages

### Technical Enhancements
- **Enhanced Error Handling**: Comprehensive validation for make commands and manufacturing requirements
- **Improved Debug System**: Categorized logging with [MAKE], [SCAN], [ERROR], etc. prefixes
- **Smart Crate Selection**: Manufacturing system selects closest available containers automatically
- **Resource Validation**: Prevents manufacturing without sufficient materials

### Configuration Options
- `production_mode`: Toggle between development and optimized production performance
- `scan_frequency`: How often to scan for containers/commands (default: 3 seconds)
- `monitor_frequency`: How often to monitor container status (default: 2 seconds)

---

## v0.2 - Base Air Drop System
**Initial Release**

### Core Features
- **C-130 Air Drop Functionality**: Complete air drop system with formation flying
- **Dynamic Marker System**: Automatic generation of drop zone markers (dp-alpha, dp-bravo, etc.)
- **Multiple Vehicle Types**: Support for M1 Abrams Tanks, M113 APCs, and M1025 HMMWVs
- **Quantity Selection**: Radio menu options for 2, 4, 6, or 8 vehicles per drop mission
- **Formation Flying**: Diamond formation for multiple C-130 aircraft
- **Cargo Delivery Mechanics**: Realistic timing and positioning for vehicle drops

### Features
- Radio menu integration with Blue coalition
- Nearest airport detection for C-130 spawning
- Dynamic route planning with waypoint system
- Group cleanup and management system
- Debug commands for troubleshooting

---

## Roadmap
- Additional vehicle types
- Advanced manufacturing recipes
- Container supply chain management
- Integration with other mission systems