# Changelog


## 1.0.0 - Inital Stable Release
  
### Changes:
- Renamed to Belt Overflow Continued
- Updated for Factorio 2.0
- Replaced global with storage throughout (Factorio 2.0 API change)
- Updated collision_mask to use the new "layers" dictionary format
- Updated asset paths from __belt-overflow__ to __BeltOverflowContinued__
- Fixed all direction arithmetic for Factorio 2.0's 16-way direction system (cardinals now 0/4/8/12 instead of 0/2/4/6)
- Used LuaEntity.belt_shape to directly detect belt curves instead of heuristic
- Updated get_chunks() to use chunk.area for find_entities_filtered
- Updated spill_item_stack to named-parameter form with allow_belts=false
- Added event filters to on_built_entity/on_robot_built_entity/on_pre_player_mined_item/on_robot_pre_mined/on_entity_died for performance
  
### Optimizations:
- Replaced full-scan polling model with rotating-slice + hot-set system
- Per-tick cost is now O(SCAN_SLICE + actively_overflowing) instead of O(all_terminal_belts)
- Belts found overflowing are promoted to a "hot set" checked every tick until they clear
- All other terminal belts are sampled in a rotating background scan (default 5/tick)
- Repurposed "Belt Polling Frequency" setting as "Belt Scan Slice Size"
- Added list_index to TerminalBelt for O(1) removal from flat list

---