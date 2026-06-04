# REAPER Agent Reference Notes

## Planner Rules

- Use only tools from the registry.
- Prefer the smallest possible plan.
- Use `get_project_state` first when the request is ambiguous.
- Use `verify_project_state` after a state change when the user cares about the result.

## Track Workflow

- `create_track` creates a track and can name it.
- `find_track` resolves an existing track by name, id, index, or selection.
- `select_track` makes one track the active selection.
- `rename_track` changes the visible track name.

## FX Workflow

- `resolve_fx` looks up local catalog entries and returns best matches.
- `insert_fx` uses `TrackFX_AddByName`.
- Prefer exact catalog matches before inventing new FX names.

## MIDI Workflow

- `create_midi_item` uses `CreateNewMIDIItemInProj`.
- `write_midi_notes` uses `MIDI_InsertNote` and `MIDI_Sort`.
- Use `MIDI_GetPPQPosFromProjTime` or `MIDI_GetPPQPosFromProjQN` when converting positions.

## Tempo And Routing

- `set_tempo` uses `SetTempoTimeSigMarker`.
- `create_send` uses `CreateTrackSend`.
- `route_track_to_bus` can create the bus track first, then create the send.

## Validation

- Track existence: resolve by id, name, or index and confirm the track still exists.
- FX insertion: confirm the FX is present in the track FX chain.
- MIDI creation: confirm the track has a MIDI take.
- Selection: confirm the selected track matches the target.
- Render/export: confirm render stats are present after render.

## Useful API Notes

- `TrackFX_AddByName(track, fxname, recFX, instantiate)` adds or queries track FX.
- `CreateNewMIDIItemInProj(track, starttime, endtime, qnIn)` creates an empty MIDI item.
- `MIDI_CountEvts(take)` returns note, CC, and text event counts.
- `CreateTrackSend(src, dest)` creates a normal send/receive pair.
- `SetTrackSendInfo_Value` can adjust send volume, pan, mode, and channel routing.
- `SetTempoTimeSigMarker(proj, ptidx, timepos, measurepos, beatpos, bpm, num, denom, lineartempo)` inserts or updates tempo markers.
- `Main_OnCommand(42230, 0)` is the common render action for "Render project using most recent settings".
