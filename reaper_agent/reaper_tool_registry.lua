local json = dofile((debug.getinfo(1, "S").source:match("^@(.+[\\/])") or "") .. "reaper_json.lua")
local plugin_catalog = dofile((debug.getinfo(1, "S").source:match("^@(.+[\\/])") or "") .. "reaper_plugin_catalog.lua")

local registry = {}
local state = {
  last_created_track = nil,
  last_created_midi_item = nil,
  last_created_midi_take = nil,
  last_operation = "none",
  last_render_stats = "",
  last_error = nil,
}

local function tool_dir()
  return debug.getinfo(1, "S").source:match("^@(.+[\\/])") or ""
end

local ROOT = tool_dir()

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function guid_or_ptr(value, fallback)
  if value and value ~= "" then
    return value
  end
  return fallback
end

local function track_guid(track)
  local ok, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
  if ok then
    return guid_or_ptr(guid, tostring(track))
  end
  return tostring(track)
end

local function item_guid(item)
  local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if ok then
    return guid_or_ptr(guid, tostring(item))
  end
  return tostring(item)
end

local function take_guid(take)
  local ok, guid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
  if ok then
    return guid_or_ptr(guid, tostring(take))
  end
  return tostring(take)
end

local function find_selected_track()
  local count = reaper.CountSelectedTracks(0)
  if count < 1 then
    return nil
  end
  return reaper.GetSelectedTrack(0, 0)
end

local function track_name(track)
  local ok, name = reaper.GetTrackName(track, "")
  if ok then
    return trim(name)
  end
  return ""
end

local function item_name(item)
  local ok, name = reaper.GetSetMediaItemInfo_String(item, "P_NAME", "", false)
  if ok then
    return trim(name)
  end
  return ""
end

local function take_name(take)
  local ok, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if ok then
    return trim(name)
  end
  return ""
end

local function fx_list(track)
  local fx_count = reaper.TrackFX_GetCount(track)
  local fx = {}
  for i = 0, fx_count - 1 do
    local ok, name = reaper.TrackFX_GetFXName(track, i)
    fx[#fx + 1] = {
      index = i,
      name = ok and trim(name) or ("FX " .. tostring(i + 1)),
    }
  end
  return fx
end

local function item_list(track)
  local item_count = reaper.CountTrackMediaItems(track)
  local items = {}
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if item then
      local take_count = reaper.CountTakes(item)
      local take = reaper.GetMediaItemTake(item, 0)
      local is_midi = false
      if take then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
          local ok, source_type = reaper.GetMediaSourceType(source, "")
          is_midi = ok and trim(source_type) == "MIDI" or false
        end
      end
      items[#items + 1] = {
        id = item_guid(item),
        name = item_name(item),
        index = i,
        position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
        takes = take_count,
        midi = is_midi,
      }
    end
  end
  return items
end

local function region_list()
  local _, marker_count, region_count = reaper.CountProjectMarkers(0)
  local total = marker_count + region_count
  local regions = {}
  for i = 0, total - 1 do
    local ok, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn then
      regions[#regions + 1] = {
        id = idx,
        name = trim(name),
        start = pos,
        finish = rgnend,
      }
    end
  end
  return regions
end

local function selected_track_info()
  local track = find_selected_track()
  if not track then
    return nil
  end
  local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  return {
    id = track_guid(track),
    name = track_name(track),
    index = idx,
  }
end

local function track_info(track, index)
  return {
    id = track_guid(track),
    name = track_name(track),
    index = index,
    fx = fx_list(track),
    items = item_list(track),
  }
end

local function track_summary(track, index)
  local info = track_info(track, index)
  return {
    id = info.id,
    name = info.name,
    index = info.index,
    fx = info.fx,
    items_count = #info.items,
    muted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") > 0,
    solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0,
  }
end

local function tool_category(name)
  local map = {
    get_project_state = "system",
    verify_project_state = "system",
    validate_tool_args = "system",
    dry_run_plan = "system",
    undo_agent_plan = "system",
    create_track = "tracks",
    find_track = "tracks",
    select_track = "tracks",
    rename_track = "tracks",
    resolve_track = "tracks",
    get_track_list = "tracks",
    get_selected_tracks = "tracks",
    get_last_created_track = "tracks",
    delete_track = "tracks",
    set_track_volume = "tracks",
    set_track_pan = "tracks",
    mute_track = "tracks",
    solo_track = "tracks",
    insert_fx = "fx",
    resolve_fx = "fx",
    get_track_fx_list = "fx",
    remove_fx = "fx",
    bypass_fx = "fx",
    set_fx_preset = "fx",
    create_midi_item = "midi",
    write_midi_notes = "midi",
    generate_bassline = "midi",
    generate_drum_pattern = "midi",
    generate_chord_progression = "midi",
    quantize_midi = "midi",
    set_tempo = "project",
    set_project_bpm = "project",
    set_project_time_signature = "project",
    create_send = "routing",
    route_track_to_bus = "routing",
    create_sidechain_send = "routing",
    play = "transport",
    stop = "transport",
    render_project = "render",
    export_stems = "render",
    create_project_snapshot = "history_versions",
    restore_project_snapshot = "history_versions",
    list_project_snapshots = "history_versions",
    delete_project_snapshot = "history_versions",
    compare_project_snapshots = "history_versions",
    create_mix_version = "history_versions",
    switch_mix_version = "history_versions",
    duplicate_project_version = "history_versions",
    tag_project_version = "history_versions",
    add_version_note = "history_versions",
    get_version_notes = "history_versions",
    rollback_to_before_agent_plan = "history_versions",
    create_auto_backup_before_execution = "history_versions",
    create_checkpoint_after_step = "history_versions",
    list_agent_checkpoints = "history_versions",
    restore_agent_checkpoint = "history_versions",
    resolve_pronoun_reference = "context_resolution",
    resolve_last_mentioned_track = "context_resolution",
    resolve_last_modified_track = "context_resolution",
    resolve_last_created_fx = "context_resolution",
    resolve_last_created_midi_item = "context_resolution",
    resolve_last_created_audio_item = "context_resolution",
    resolve_last_selected_object = "context_resolution",
    resolve_target_from_dialog_context = "context_resolution",
    save_dialog_reference = "context_resolution",
    clear_dialog_reference = "context_resolution",
    get_dialog_context_state = "context_resolution",
    ask_clarification_for_ambiguous_reference = "context_resolution",
    create_articulation_map = "articulations",
    assign_articulation_to_midi_notes = "articulations",
    insert_keyswitch = "articulations",
    insert_keyswitch_sequence = "articulations",
    detect_existing_keyswitches = "articulations",
    remove_keyswitches = "articulations",
    convert_keyswitches_to_articulations = "articulations",
    set_midi_articulation_legato = "articulations",
    set_midi_articulation_staccato = "articulations",
    set_midi_articulation_spiccato = "articulations",
    set_midi_articulation_pizzicato = "articulations",
    set_midi_articulation_tremolo = "articulations",
    set_midi_articulation_sustain = "articulations",
    generate_string_expression_cc = "articulations",
    generate_brass_expression_cc = "articulations",
    humanize_orchestral_midi = "articulations",
    create_orchestral_velocity_curve = "articulations",
    extract_groove_from_midi = "groove_timing",
    extract_groove_from_audio = "groove_timing",
    apply_groove_to_midi = "groove_timing",
    apply_groove_to_audio_items = "groove_timing",
    set_swing_amount = "groove_timing",
    set_track_groove_template = "groove_timing",
    create_groove_template = "groove_timing",
    save_groove_template = "groove_timing",
    load_groove_template = "groove_timing",
    nudge_notes_ahead = "groove_timing",
    nudge_notes_late = "groove_timing",
    humanize_drums_by_role = "groove_timing",
    tighten_drums_to_kick = "groove_timing",
    loosen_midi_performance = "groove_timing",
    quantize_with_strength = "groove_timing",
    quantize_only_note_starts = "groove_timing",
    quantize_only_note_ends = "groove_timing",
    quantize_preserve_velocity = "groove_timing",
    create_chord_track = "harmony",
    detect_chords_from_midi = "harmony",
    detect_chords_from_audio = "harmony",
    write_chord_markers = "harmony",
    create_chord_regions = "harmony",
    generate_chord_progression_by_style = "harmony",
    reharmonize_chord_progression = "harmony",
    transpose_project_to_key = "harmony",
    transpose_selected_tracks_to_key = "harmony",
    force_midi_to_chord_progression = "harmony",
    generate_topline_over_chords = "harmony",
    generate_bassline_from_chords = "harmony",
    generate_countermelody_from_chords = "harmony",
    create_modal_interchange_variation = "harmony",
    create_secondary_dominant_variation = "harmony",
    simplify_chord_progression = "harmony",
    make_chords_more_pop = "harmony",
    make_chords_more_jazz = "harmony",
    make_chords_darker = "harmony",
    make_chords_brighter = "harmony",
    analyze_arrangement_energy = "arrangement_intelligence",
    create_energy_map = "arrangement_intelligence",
    apply_energy_map_to_arrangement = "arrangement_intelligence",
    create_tension_release_plan = "arrangement_intelligence",
    add_pre_drop_silence = "arrangement_intelligence",
    add_impact_on_section_start = "arrangement_intelligence",
    add_reverse_before_transition = "arrangement_intelligence",
    add_crash_on_section_start = "arrangement_intelligence",
    add_fill_before_section = "arrangement_intelligence",
    thin_out_arrangement_section = "arrangement_intelligence",
    thicken_arrangement_section = "arrangement_intelligence",
    remove_elements_from_breakdown = "arrangement_intelligence",
    add_elements_to_second_drop = "arrangement_intelligence",
    create_call_response_between_tracks = "arrangement_intelligence",
    create_variation_every_4_bars = "arrangement_intelligence",
    create_transition_between_regions = "arrangement_intelligence",
    copy_arrangement_section = "arrangement_intelligence",
    mutate_arrangement_section = "arrangement_intelligence",
    create_radio_edit_structure = "arrangement_intelligence",
    create_extended_mix_structure = "arrangement_intelligence",
    create_tiktok_short_structure = "arrangement_intelligence",
    find_loudest_audio_item = "semantic_audio_editing",
    find_quietest_audio_item = "semantic_audio_editing",
    find_audio_items_with_silence = "semantic_audio_editing",
    remove_silence_from_items = "semantic_audio_editing",
    trim_silence_from_item_edges = "semantic_audio_editing",
    find_transient_peaks = "semantic_audio_editing",
    align_items_by_transients = "semantic_audio_editing",
    detect_audio_loop_length = "semantic_audio_editing",
    make_audio_loop_seamless = "semantic_audio_editing",
    create_loop_from_selection = "semantic_audio_editing",
    slice_loop_to_drum_rack = "semantic_audio_editing",
    chop_sample_by_grid = "semantic_audio_editing",
    chop_sample_by_transients = "semantic_audio_editing",
    rearrange_sample_chops = "semantic_audio_editing",
    create_stutter_edit = "semantic_audio_editing",
    create_glitch_edit = "semantic_audio_editing",
    create_tape_stop_effect = "semantic_audio_editing",
    create_reverse_reverb_effect = "semantic_audio_editing",
    create_vocal_chop_pattern = "semantic_audio_editing",
    create_fill_from_audio_slice = "semantic_audio_editing",
    measure_integrated_lufs = "metering_quality_control",
    measure_short_term_lufs = "metering_quality_control",
    measure_momentary_lufs = "metering_quality_control",
    measure_true_peak = "metering_quality_control",
    measure_peak_level = "metering_quality_control",
    measure_rms_level = "metering_quality_control",
    measure_dynamic_range = "metering_quality_control",
    measure_crest_factor = "metering_quality_control",
    measure_phase_correlation = "metering_quality_control",
    measure_stereo_width = "metering_quality_control",
    measure_low_end_mono_compatibility = "metering_quality_control",
    check_mono_compatibility = "metering_quality_control",
    check_streaming_loudness_target = "metering_quality_control",
    check_headroom = "metering_quality_control",
    check_inter_sample_peaks = "metering_quality_control",
    find_frequency_masking = "metering_quality_control",
    find_resonances = "metering_quality_control",
    find_harshness_zones = "metering_quality_control",
    find_muddy_tracks = "metering_quality_control",
    find_boxy_tracks = "metering_quality_control",
    find_sibilance = "metering_quality_control",
    create_mix_quality_report = "metering_quality_control",
    create_master_quality_report = "metering_quality_control",
    prepare_stems_for_client = "delivery",
    prepare_stems_for_mixing = "delivery",
    prepare_stems_for_mastering = "delivery",
    prepare_instrumental_export = "delivery",
    prepare_acapella_export = "delivery",
    prepare_tv_mix_export = "delivery",
    prepare_no_drums_export = "delivery",
    prepare_no_bass_export = "delivery",
    prepare_karaoke_export = "delivery",
    prepare_clean_version = "delivery",
    prepare_explicit_version = "delivery",
    prepare_30sec_preview = "delivery",
    prepare_15sec_preview = "delivery",
    prepare_loop_pack_export = "delivery",
    prepare_sample_pack_export = "delivery",
    create_delivery_folder_structure = "delivery",
    create_delivery_readme = "delivery",
    export_mix_versions = "delivery",
    export_alt_versions = "delivery",
    zip_delivery_package = "delivery",
    verify_delivery_files = "delivery",
    name_exports_by_standard = "delivery",
    create_loop_pack_from_project = "sample_pack_creation",
    export_selected_items_as_loops = "sample_pack_creation",
    normalize_loops_to_target_peak = "sample_pack_creation",
    trim_loops_to_bar_length = "sample_pack_creation",
    add_bpm_to_filenames = "sample_pack_creation",
    add_key_to_filenames = "sample_pack_creation",
    detect_key_for_loops = "sample_pack_creation",
    detect_bpm_for_loops = "sample_pack_creation",
    categorize_loops_by_type = "sample_pack_creation",
    create_one_shots_from_drums = "sample_pack_creation",
    export_drum_one_shots = "sample_pack_creation",
    create_sampler_patches_from_samples = "sample_pack_creation",
    create_loop_pack_metadata = "sample_pack_creation",
    create_preview_demo_for_sample_pack = "sample_pack_creation",
    create_sample_pack_folder_structure = "sample_pack_creation",
    verify_loop_seamlessness = "sample_pack_creation",
    create_vocal_recording_session = "recording_session_setup",
    create_guitar_recording_session = "recording_session_setup",
    create_bass_recording_session = "recording_session_setup",
    create_drums_recording_session = "recording_session_setup",
    create_podcast_recording_session = "recording_session_setup",
    create_voiceover_recording_session = "recording_session_setup",
    set_recording_latency_compensation = "recording_session_setup",
    create_talkback_track = "recording_session_setup",
    create_cue_mix = "recording_session_setup",
    create_headphone_mix = "recording_session_setup",
    route_click_to_headphones = "recording_session_setup",
    route_track_to_headphone_mix = "recording_session_setup",
    arm_recording_template_tracks = "recording_session_setup",
    create_take_lanes_for_recording = "recording_session_setup",
    label_recording_takes = "recording_session_setup",
    create_recording_markers = "recording_session_setup",
    create_recording_notes = "recording_session_setup",
    backup_recording_session = "recording_session_setup",
    prepare_session_for_next_take = "recording_session_setup",
    create_comp_from_best_takes = "performance_editing",
    rate_takes = "performance_editing",
    mark_bad_takes = "performance_editing",
    mark_good_takes = "performance_editing",
    split_takes_by_phrase = "performance_editing",
    comp_vocal_by_phrases = "performance_editing",
    comp_guitar_by_phrases = "performance_editing",
    align_backing_vocals_to_lead = "performance_editing",
    align_doubles_to_main = "performance_editing",
    tighten_bass_to_kick = "performance_editing",
    tighten_guitar_to_drums = "performance_editing",
    create_vocal_crossfades = "performance_editing",
    smooth_comp_transitions = "performance_editing",
    remove_breaths = "performance_editing",
    reduce_breaths = "performance_editing",
    keep_natural_breaths = "performance_editing",
    clean_mouth_clicks = "performance_editing",
    clean_plosives = "performance_editing",
    de_noise_recorded_track = "performance_editing",
    create_riser = "sound_design",
    create_downlifter = "sound_design",
    create_impact = "sound_design",
    create_sub_drop = "sound_design",
    create_noise_sweep = "sound_design",
    create_reverse_crash = "sound_design",
    create_vinyl_stop = "sound_design",
    create_pitch_ramp = "sound_design",
    create_filter_sweep = "sound_design",
    create_granular_texture = "sound_design",
    create_drone_texture = "sound_design",
    create_atmospheric_bed = "sound_design",
    create_cinematic_hit = "sound_design",
    create_glitch_fill = "sound_design",
    create_vocal_throw_fx = "sound_design",
    create_delay_throw_fx = "sound_design",
    create_reverb_swell = "sound_design",
    create_distorted_808 = "sound_design",
    create_reese_bass = "sound_design",
    create_pluck_sound = "sound_design",
    create_pad_sound = "sound_design",
    create_lead_sound = "sound_design",
    create_cowbell_sound = "sound_design",
    create_phonk_texture = "sound_design",
    resample_track_to_audio = "sound_design",
    resample_fx_tail = "sound_design",
    print_sound_design_layer = "sound_design",
    generate_kick_pattern = "drum_midi_generation",
    generate_snare_pattern = "drum_midi_generation",
    generate_clap_pattern = "drum_midi_generation",
    generate_closed_hat_pattern = "drum_midi_generation",
    generate_open_hat_pattern = "drum_midi_generation",
    generate_percussion_pattern = "drum_midi_generation",
    generate_tom_fill = "drum_midi_generation",
    generate_snare_fill = "drum_midi_generation",
    generate_hat_roll = "drum_midi_generation",
    generate_triplet_hat_roll = "drum_midi_generation",
    generate_drum_fill_before_region = "drum_midi_generation",
    generate_drum_variation = "drum_midi_generation",
    generate_ghost_notes = "drum_midi_generation",
    generate_syncopated_kick_pattern = "drum_midi_generation",
    generate_brazilian_funk_drum_pattern = "drum_midi_generation",
    generate_phonk_drum_loop = "drum_midi_generation",
    generate_trap_drum_loop = "drum_midi_generation",
    generate_house_drum_loop = "drum_midi_generation",
    map_drum_notes_to_plugin = "drum_midi_generation",
    convert_drum_midi_to_general_midi = "drum_midi_generation",
    split_drum_midi_to_tracks = "drum_midi_generation",
    generate_808_bassline = "bass_generation",
    generate_sub_bassline = "bass_generation",
    generate_reese_bassline = "bass_generation",
    generate_funk_bassline = "bass_generation",
    generate_rock_bassline = "bass_generation",
    generate_house_bassline = "bass_generation",
    generate_phonk_bassline = "bass_generation",
    generate_brazilian_phonk_bassline = "bass_generation",
    create_808_slides = "bass_generation",
    create_bass_glides = "bass_generation",
    tune_808_to_key = "bass_generation",
    force_bass_to_kick_rhythm = "bass_generation",
    simplify_bassline = "bass_generation",
    make_bassline_more_aggressive = "bass_generation",
    make_bassline_more_groovy = "bass_generation",
    make_bassline_less_busy = "bass_generation",
    layer_sub_under_bass = "bass_generation",
    create_bass_distortion_parallel = "bass_generation",
    mono_low_bass = "bass_generation",
    detect_vocal_phrases = "vocal_chop_remix",
    slice_vocal_by_phrases = "vocal_chop_remix",
    slice_vocal_by_syllables = "vocal_chop_remix",
    create_vocal_chop_sampler = "vocal_chop_remix",
    map_vocal_chops_to_keys = "vocal_chop_remix",
    generate_vocal_chop_melody = "vocal_chop_remix",
    create_vocal_chop_rhythm = "vocal_chop_remix",
    pitch_vocal_chops_to_key = "vocal_chop_remix",
    formant_shift_vocal_chops = "vocal_chop_remix",
    reverse_selected_vocal_chops = "vocal_chop_remix",
    stutter_vocal_chops = "vocal_chop_remix",
    create_vocal_chop_drop = "vocal_chop_remix",
    create_vocal_chop_hook = "vocal_chop_remix",
    create_vocal_chop_transition = "vocal_chop_remix",
    clean_vocal_chop_edges = "vocal_chop_remix",
    export_vocal_chop_pack = "vocal_chop_remix",
    create_reference_analysis_report = "reference_matching_extended",
    detect_reference_sections = "reference_matching_extended",
    detect_reference_bpm_changes = "reference_matching_extended",
    detect_reference_drop_points = "reference_matching_extended",
    detect_reference_breakdowns = "reference_matching_extended",
    detect_reference_instrument_entries = "reference_matching_extended",
    create_reference_energy_markers = "reference_matching_extended",
    match_arrangement_length_to_reference = "reference_matching_extended",
    match_section_lengths_to_reference = "reference_matching_extended",
    match_drop_timing_to_reference = "reference_matching_extended",
    match_low_end_level_to_reference = "reference_matching_extended",
    match_vocal_level_to_reference = "reference_matching_extended",
    match_brightness_to_reference = "reference_matching_extended",
    match_stereo_width_to_reference = "reference_matching_extended",
    compare_spectrum_to_reference = "reference_matching_extended",
    compare_loudness_to_reference = "reference_matching_extended",
    create_reference_ab_markers = "reference_matching_extended",
    show_plan_to_user = "chat_ui_agent",
    show_execution_progress = "chat_ui_agent",
    show_failed_step = "chat_ui_agent",
    show_repair_options = "chat_ui_agent",
    show_available_tools_for_request = "chat_ui_agent",
    show_project_state_summary = "chat_ui_agent",
    show_last_changes = "chat_ui_agent",
    show_undo_options = "chat_ui_agent",
    show_ambiguous_targets = "chat_ui_agent",
    confirm_dangerous_action = "chat_ui_agent",
    ask_user_to_choose_plugin = "chat_ui_agent",
    ask_user_to_choose_track = "chat_ui_agent",
    ask_user_to_choose_region = "chat_ui_agent",
    explain_why_command_failed = "chat_ui_agent",
    explain_what_was_done = "chat_ui_agent",
    toggle_verbose_agent_logs = "chat_ui_agent",
    toggle_silent_execution = "chat_ui_agent",
    create_full_brazilian_phonk_demo = "recipes_extended",
    create_phonk_loop_pack = "recipes_extended",
    create_vocal_recording_template = "recipes_extended",
    create_rap_vocal_mix_template = "recipes_extended",
    create_pop_song_demo = "recipes_extended",
    create_rock_band_template = "recipes_extended",
    create_funk_groove_template = "recipes_extended",
    create_orchestral_sketch_template = "recipes_extended",
    create_cinematic_trailer_template = "recipes_extended",
    create_mix_prep_session = "recipes_extended",
    create_mastering_session = "recipes_extended",
    create_client_delivery_package = "recipes_extended",
    create_sample_pack_from_session = "recipes_extended",
    create_reference_based_arrangement = "recipes_extended",
    create_sidechain_system = "recipes_extended",
    create_vocal_chop_instrument = "recipes_extended",
    create_drum_replacement_workflow = "recipes_extended",
    create_clean_edit_version = "recipes_extended",
    create_social_media_snippet = "recipes_extended",
    create_stem_master_check = "recipes_extended",
  }
  return map[name] or "analysis"
end

local function make_stub_result(name, category, fallback)
  return {
    implementation_status = "stub",
    fallback = fallback or "ask_user",
    tool = name,
    category = category,
  }
end

local function stub_tool(name, category, description, example_phrase, fallback)
  return {
    name = name,
    category = category,
    description = description,
    json_schema = { type = "object", properties = {} },
    example_user_phrase = example_phrase or "",
    execute = function(_args)
      return true, make_stub_result(name, category, fallback)
    end,
    possible_errors = {},
    result_format = "Stubbed tool metadata with fallback.",
    implementation_status = "stub",
    fallback = fallback or "ask_user",
  }
end

local function all_tracks()
  local count = reaper.CountTracks(0)
  local tracks = {}
  for i = 0, count - 1 do
    local track = reaper.GetTrack(0, i)
    if track then
      tracks[#tracks + 1] = track_info(track, i + 1)
    end
  end
  return tracks
end

local function current_snapshot()
  return {
    tempo = reaper.Master_GetTempo(),
    time_signature = "4/4",
    selected_track = selected_track_info(),
    tracks = all_tracks(),
    regions = region_list(),
    last_created_track = state.last_created_track,
    last_operation = state.last_operation,
    last_error = state.last_error,
  }
end

local function get_track_list()
  return all_tracks()
end

local function get_selected_tracks()
  local track = find_selected_track()
  if not track then
    return {}
  end
  local index = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  return { track_summary(track, index) }
end

local function get_last_created_track()
  return state.last_created_track
end

local function resolve_track_public(args)
  local track, index = resolve_track_selector(args or {})
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  return true, { track = track_summary(track, index) }
end

local function get_track_fx_list(args)
  local track, index = resolve_track_selector(args or {})
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  return true, { track = track_summary(track, index), fx = fx_list(track) }
end

local function beats_per_bar()
  return 4
end

local function midi_bars_to_seconds(bars)
  local bpm = reaper.Master_GetTempo()
  local beats = tonumber(bars or 1) * beats_per_bar()
  return beats * 60.0 / math.max(bpm, 1)
end

local function generate_bassline(args)
  args = args or {}
  local bars = math.max(1, tonumber(args.bars or 8) or 8)
  local style = normalize(args.style or "aggressive")
  local root = tonumber(args.root or args.root_pitch or 36) or 36

  local notes = {}
  local pattern = {
    { 0.0, 0.5, 0 },
    { 0.5, 1.0, 7 },
    { 1.0, 1.5, 0 },
    { 1.5, 2.0, 10 },
    { 2.0, 2.5, 0 },
    { 2.5, 3.0, 7 },
    { 3.0, 3.5, 0 },
    { 3.5, 4.0, 12 },
  }

  local variation = style:find("phonk", 1, true) and 1 or 0
  for bar = 0, bars - 1 do
    local bar_offset = bar * 4
    for _, step in ipairs(pattern) do
      local start_qn = bar_offset + step[1]
      local end_qn = bar_offset + step[2]
      local pitch = root + step[3]
      if variation == 1 and (bar % 4 == 3) then
        pitch = pitch + 12
      end
      notes[#notes + 1] = {
        start_qn = start_qn,
        end_qn = end_qn,
        pitch = pitch,
        velocity = 100,
        channel = 0,
      }
    end
  end

  return true, {
    style = args.style or "aggressive",
    bars = bars,
    notes = notes,
    note_count = #notes,
  }
end

local function generate_chord_progression(args)
  args = args or {}
  local bars = math.max(1, tonumber(args.bars or 4) or 4)
  local key = trim(args.key or "Am")
  local root = tonumber(args.root or 57) or 57
  local pattern = {
    { 0, 4, 7 },
    { 5, 9, 12 },
    { 7, 11, 14 },
    { 2, 5, 9 },
  }
  local notes = {}
  for bar = 0, bars - 1 do
    local chord = pattern[(bar % #pattern) + 1]
    for _, interval in ipairs(chord) do
      notes[#notes + 1] = {
        start_qn = bar * 4,
        end_qn = bar * 4 + 4,
        pitch = root + interval,
        velocity = 88,
        channel = 0,
      }
    end
  end
  return true, {
    key = key,
    bars = bars,
    notes = notes,
    note_count = #notes,
  }
end

local function normalize(text)
  return trim(tostring(text or ""):lower())
end

local function resolve_track_selector(args)
  args = args or {}
  if args.track_ref == "selected" then
    args.selected = true
  elseif args.track_ref == "last_created" then
    args.track = "last_created"
  end
  if args.track_id then
    local target = normalize(args.track_id)
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      if track and normalize(track_guid(track)) == target then
        return track, i + 1
      end
    end
  end

  if args.track_index ~= nil then
    local index = tonumber(args.track_index)
    if index and index >= 1 and index <= reaper.CountTracks(0) then
      return reaper.GetTrack(0, index - 1), index
    end
  end

  if args.selected then
    local track = find_selected_track()
    if track then
      local index = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
      return track, index
    end
  end

  if args.track_name then
    local wanted = normalize(args.track_name)
    local best
    local best_score = 0
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      if track then
        local name = normalize(track_name(track))
        if name == wanted then
          return track, i + 1
        end
        if name:find(wanted, 1, true) then
          local score = #wanted / math.max(#name, 1)
          if score > best_score then
            best = { track = track, index = i + 1 }
            best_score = score
          end
        end
      end
    end
    if best then
      return best.track, best.index
    end
  end

  if args.track == "last_created" and state.last_created_track then
    return resolve_track_selector({ track_id = state.last_created_track.id })
  end

  return nil, nil
end

local function find_fx_in_catalog(query)
  local q = normalize(query)
  local matches = {}
  for _, plugin in ipairs(plugin_catalog) do
    local haystacks = {
      normalize(plugin.display_name),
      normalize(plugin.exact_reaper_fx_name),
      normalize(plugin.type),
      normalize(plugin.vendor),
      normalize(plugin.category),
      normalize(plugin.format),
    }
    for _, alias in ipairs(plugin.aliases or {}) do
      haystacks[#haystacks + 1] = normalize(alias)
    end
    for _, tag in ipairs(plugin.tags or {}) do
      haystacks[#haystacks + 1] = normalize(tag)
    end
    local matched = false
    for _, item in ipairs(haystacks) do
      if item == q or item:find(q, 1, true) or q:find(item, 1, true) then
        matched = true
        break
      end
    end
    if matched then
      matches[#matches + 1] = plugin
    end
  end
  return matches
end

local function read_render_stats()
  local ok, stats = reaper.GetSetProjectInfo_String(0, "RENDER_STATS_SUMMARY", "", false)
  if ok then
    return trim(stats)
  end
  return ""
end

local function verify_track_exists(args)
  local track, index = resolve_track_selector(args or {})
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  return true, { track = track_info(track, index) }
end

local function verify_selected_track(args)
  local expected = args or {}
  local actual = selected_track_info()
  if not actual then
    return false, { error = "no_selected_track", message = "No selected track." }
  end
  if expected.track_name and normalize(actual.name) ~= normalize(expected.track_name) then
    return false, { error = "selected_track_mismatch", message = "Selected track does not match." }
  end
  if expected.track_id and normalize(actual.id) ~= normalize(expected.track_id) then
    return false, { error = "selected_track_mismatch", message = "Selected track does not match." }
  end
  return true, { track = actual }
end

local function verify_fx_inserted(args)
  local track, index = resolve_track_selector(args or {})
  if not track then
    return false, { error = "track_not_found", message = "Track not found for FX check." }
  end
  local fx_name = args.fx_name or args.query or ""
  local target = normalize(fx_name)
  local fx_count = reaper.TrackFX_GetCount(track)
  for i = 0, fx_count - 1 do
    local ok, name = reaper.TrackFX_GetFXName(track, i)
    if ok and normalize(name):find(target, 1, true) then
      return true, { track = track_info(track, index), fx = name }
    end
  end
  return false, { error = "fx_not_found", message = "FX was not found on track." }
end

local function verify_midi_item_created(args)
  local track, index = resolve_track_selector(args or {})
  if not track then
    return false, { error = "track_not_found", message = "Track not found for MIDI check." }
  end
  local count = reaper.CountTrackMediaItems(track)
  if count < 1 then
    return false, { error = "midi_item_missing", message = "No item on track." }
  end
  for i = 0, count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if item then
      local take = reaper.GetMediaItemTake(item, 0)
      if take then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
          local ok, source_type = reaper.GetMediaSourceType(source, "")
          if ok and trim(source_type) == "MIDI" then
            return true, { track = track_info(track, index), item = { id = item_guid(item), take = take_guid(take) } }
          end
        end
      end
    end
  end
  return false, { error = "midi_item_missing", message = "No MIDI item found." }
end

local function verify_render_completed()
  local stats = read_render_stats()
  if stats == "" then
    return false, { error = "render_not_completed", message = "No render statistics found." }
  end
  return true, { stats = stats }
end

local function create_track(args)
  args = args or {}
  local before = reaper.CountTracks(0)
  reaper.Undo_BeginBlock2(0)
  reaper.InsertTrackAtIndex(before, true)
  local track = reaper.GetTrack(0, before)
  if not track then
    reaper.Undo_EndBlock2(0, "Create track failed", -1)
    return false, { error = "track_create_failed", message = "Failed to create track." }
  end
  local name = trim(args.name or args.track_name or "")
  if name ~= "" then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  end
  if args.select_after ~= false then
    reaper.SetOnlyTrackSelected(track)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(0, "Create track", -1)

  local index = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  local info = track_info(track, index)
  local selected = selected_track_info()
  state.last_created_track = info
  state.last_operation = "create_track"

  return true, {
    track = info,
    created = reaper.CountTracks(0) == before + 1,
    selected = selected and normalize(selected.id) == normalize(info.id) or false,
  }
end

local function find_track(args)
  local track, index = resolve_track_selector(args or {})
  if not track then
    local matches = {}
    local query = normalize((args or {}).query or (args or {}).track_name or "")
    for i = 0, reaper.CountTracks(0) - 1 do
      local candidate = reaper.GetTrack(0, i)
      if candidate then
        local name = normalize(track_name(candidate))
        if query == "" or name:find(query, 1, true) then
          matches[#matches + 1] = track_info(candidate, i + 1)
        end
      end
    end
    return true, { matches = matches, found = #matches > 0 }
  end

  return true, { track = track_info(track, index), found = true }
end

local function select_track(args)
  local track, index = resolve_track_selector(args or {})
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  reaper.SetOnlyTrackSelected(track)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  state.last_operation = "select_track"
  local selected = selected_track_info()
  if not selected or normalize(selected.id) ~= normalize(track_guid(track)) then
    return false, { error = "selection_failed", message = "Track was not selected." }
  end
  return true, { track = track_info(track, index), selected = selected }
end

local function rename_track(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  local new_name = trim(args.new_name or args.name or "")
  if new_name == "" then
    return false, { error = "missing_name", message = "New track name is required." }
  end
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", new_name, true)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  state.last_operation = "rename_track"
  return true, {
    track = track_info(track, index),
    new_name = new_name,
    verified = track_name(track) == new_name,
  }
end

local function delete_track(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end

  if reaper.DeleteTrack then
    reaper.DeleteTrack(track)
  else
    return false, { error = "delete_failed", message = "DeleteTrack is unavailable." }
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  state.last_operation = "delete_track"
  return true, {
    deleted = true,
    track = track_info(track, index),
  }
end

local function set_track_volume(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  local volume = tonumber(args.volume or args.value)
  if not volume then
    return false, { error = "missing_volume", message = "Volume value is required." }
  end
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", volume)
  state.last_operation = "set_track_volume"
  return true, { track = track_info(track, index), volume = volume }
end

local function set_track_pan(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  local pan = tonumber(args.pan or args.value)
  if pan == nil then
    return false, { error = "missing_pan", message = "Pan value is required." }
  end
  reaper.SetMediaTrackInfo_Value(track, "D_PAN", pan)
  state.last_operation = "set_track_pan"
  return true, { track = track_info(track, index), pan = pan }
end

local function mute_track(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  local mute = args.mute
  if mute == nil then
    mute = true
  end
  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", mute and 1 or 0)
  state.last_operation = "mute_track"
  return true, { track = track_info(track, index), muted = mute and true or false }
end

local function solo_track(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found." }
  end
  local solo = args.solo
  if solo == nil then
    solo = true
  end
  reaper.SetMediaTrackInfo_Value(track, "I_SOLO", solo and 1 or 0)
  state.last_operation = "solo_track"
  return true, { track = track_info(track, index), solo = solo and true or false }
end

local function resolve_fx(args)
  args = args or {}
  local query = trim(args.query or args.fx_name or args.name or "")
  if query == "" then
    return false, { error = "missing_query", message = "FX query is required." }
  end

  local matches = find_fx_in_catalog(query)
  if #matches == 0 then
    return false, {
      error = "fx_not_found",
      message = "FX not found in local catalog.",
      catalog_matches = {},
    }
  end

  return true, {
    query = query,
    matches = matches,
    best_match = matches[1],
  }
end

local function insert_fx(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found for FX insert." }
  end

  local fx_query = trim(args.fx_name or args.query or args.name or "")
  if fx_query == "" then
    return false, { error = "missing_fx_name", message = "FX name is required." }
  end

  local candidate_fx_names = { fx_query }
  local catalog_matches = find_fx_in_catalog(fx_query)
  if #catalog_matches > 0 then
    local best = catalog_matches[1]
    if best.exact_reaper_fx_name and best.exact_reaper_fx_name ~= "" then
      candidate_fx_names[#candidate_fx_names + 1] = best.exact_reaper_fx_name
    end
    if best.display_name and best.display_name ~= "" then
      candidate_fx_names[#candidate_fx_names + 1] = best.display_name
    end
  end

  local before = reaper.TrackFX_GetCount(track)
  local fx_index = -1
  local added_name = nil
  for _, candidate in ipairs(candidate_fx_names) do
    fx_index = reaper.TrackFX_AddByName(track, candidate, false, 1)
    if fx_index >= 0 then
      added_name = candidate
      break
    end
  end
  if fx_index < 0 then
    return false, { error = "fx_insert_failed", message = "REAPER did not add the FX." }
  end

  local after = reaper.TrackFX_GetCount(track)
  local ok, fx_name = reaper.TrackFX_GetFXName(track, fx_index)
  state.last_operation = "insert_fx"
  return true, {
    track = track_info(track, index),
    fx = {
      index = fx_index,
      name = ok and fx_name or added_name or fx_query,
    },
    inserted = after >= before,
  }
end

local function remove_fx(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found for FX remove." }
  end
  local fx_name = trim(args.fx_name or args.query or args.name or "")
  if fx_name == "" then
    return false, { error = "missing_fx_name", message = "FX name is required." }
  end
  local fx_count = reaper.TrackFX_GetCount(track)
  for i = fx_count - 1, 0, -1 do
    local ok, name = reaper.TrackFX_GetFXName(track, i)
    if ok and normalize(name):find(normalize(fx_name), 1, true) then
      if reaper.TrackFX_Delete then
        reaper.TrackFX_Delete(track, i)
      else
        return false, { error = "fx_remove_failed", message = "TrackFX_Delete is unavailable." }
      end
      state.last_operation = "remove_fx"
      return true, {
        track = track_info(track, index),
        removed = true,
        fx_name = name,
      }
    end
  end
  return false, { error = "fx_not_found", message = "FX was not found on track." }
end

local function bypass_fx(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found for FX bypass." }
  end
  local fx_name = trim(args.fx_name or args.query or args.name or "")
  if fx_name == "" then
    return false, { error = "missing_fx_name", message = "FX name is required." }
  end
  local enabled = args.enabled
  if enabled == nil then
    enabled = false
  end
  local fx_count = reaper.TrackFX_GetCount(track)
  for i = 0, fx_count - 1 do
    local ok, name = reaper.TrackFX_GetFXName(track, i)
    if ok and normalize(name):find(normalize(fx_name), 1, true) then
      if reaper.TrackFX_SetEnabled then
        reaper.TrackFX_SetEnabled(track, i, enabled and true or false)
      else
        return false, { error = "fx_bypass_failed", message = "TrackFX_SetEnabled is unavailable." }
      end
      state.last_operation = "bypass_fx"
      return true, { track = track_info(track, index), fx_name = name, enabled = enabled and true or false }
    end
  end
  return false, { error = "fx_not_found", message = "FX was not found on track." }
end

local function set_fx_preset(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found for FX preset." }
  end
  local fx_name = trim(args.fx_name or args.query or args.name or "")
  local preset = trim(args.preset or args.preset_name or "")
  if fx_name == "" or preset == "" then
    return false, { error = "missing_fx_or_preset", message = "FX name and preset are required." }
  end
  local fx_count = reaper.TrackFX_GetCount(track)
  for i = 0, fx_count - 1 do
    local ok, name = reaper.TrackFX_GetFXName(track, i)
    if ok and normalize(name):find(normalize(fx_name), 1, true) then
      local applied = false
      if reaper.TrackFX_SetPreset then
        applied = reaper.TrackFX_SetPreset(track, i, preset)
      end
      if not applied then
        return false, { error = "preset_set_failed", message = "Preset could not be applied." }
      end
      state.last_operation = "set_fx_preset"
      return true, { track = track_info(track, index), fx_name = name, preset = preset }
    end
  end
  return false, { error = "fx_not_found", message = "FX was not found on track." }
end

local function create_midi_item(args)
  args = args or {}
  local track, index = resolve_track_selector(args)
  if not track then
    return false, { error = "track_not_found", message = "Track not found for MIDI item." }
  end

  local start_time = tonumber(args.start_time or args.start or 0)
  local end_time = tonumber(args.end_time or args.finish)
  if not end_time then
    local length = tonumber(args.length)
    if not length and args.bars ~= nil then
      length = midi_bars_to_seconds(args.bars)
    end
    end_time = start_time + (tonumber(length or 1) or 1)
  end
  local qn_mode = args.qn_mode == true or args.qn == true
  local item = reaper.CreateNewMIDIItemInProj(track, start_time, end_time, qn_mode)
  if not item then
    return false, { error = "midi_item_create_failed", message = "REAPER did not create a MIDI item." }
  end
  local take = reaper.GetMediaItemTake(item, 0)
  if not take then
    take = reaper.AddTakeToMediaItem(item)
  end
  if not take then
    return false, { error = "midi_take_missing", message = "MIDI take was not created." }
  end

  reaper.UpdateArrange()
  state.last_created_midi_item = {
    id = item_guid(item),
    track = track_info(track, index),
    start_time = start_time,
    end_time = end_time,
  }
  state.last_created_midi_take = take_guid(take)
  state.last_operation = "create_midi_item"

  return true, {
    track = track_info(track, index),
    item = {
      id = item_guid(item),
      take = take_guid(take),
      start_time = start_time,
      end_time = end_time,
    },
    verified = true,
  }
end

local function resolve_take(args)
  args = args or {}
  if args.take_id then
    local target = normalize(args.take_id)
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      if track then
        for j = 0, reaper.CountTrackMediaItems(track) - 1 do
          local item = reaper.GetTrackMediaItem(track, j)
          local take = item and reaper.GetMediaItemTake(item, 0) or nil
          if take and normalize(take_guid(take)) == target then
            return take, item, track, i + 1
          end
        end
      end
    end
  end
  if state.last_created_midi_take then
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      if track then
        for j = 0, reaper.CountTrackMediaItems(track) - 1 do
          local item = reaper.GetTrackMediaItem(track, j)
          local take = item and reaper.GetMediaItemTake(item, 0) or nil
          if take and normalize(take_guid(take)) == normalize(state.last_created_midi_take) then
            return take, item, track, i + 1
          end
        end
      end
    end
  end
  local track, index = resolve_track_selector(args)
  if track then
    local count = reaper.CountTrackMediaItems(track)
    for i = 0, count - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      if item then
        local take = reaper.GetMediaItemTake(item, 0)
        if take then
          local source = reaper.GetMediaItemTake_Source(take)
          if source then
            local ok, source_type = reaper.GetMediaSourceType(source, "")
            if ok and trim(source_type) == "MIDI" then
              return take, item, track, index
            end
          end
        end
      end
    end
  end
  return nil, nil, nil, nil
end

local function write_midi_notes(args)
  args = args or {}
  local take, item, track, index = resolve_take(args)
  if not take then
    return false, { error = "midi_take_not_found", message = "No MIDI take available." }
  end

  local notes = args.notes or {}
  if type(notes) ~= "table" or #notes == 0 then
    return false, { error = "missing_notes", message = "Notes array is required." }
  end

  local inserted = 0
  reaper.MIDI_DisableSort(take)
  for _, note in ipairs(notes) do
    local start_qn = nil
    local start_time = nil
    local start_ppq
    if note.start_ppq ~= nil then
      start_ppq = tonumber(note.start_ppq)
    elseif note.start_time ~= nil then
      start_time = tonumber(note.start_time)
      start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, start_time)
    elseif note.start_qn ~= nil then
      start_qn = tonumber(note.start_qn)
      start_ppq = reaper.MIDI_GetPPQPosFromProjQN(take, start_qn)
    else
      start_ppq = 0
    end

    local end_ppq
    if note.end_ppq ~= nil then
      end_ppq = tonumber(note.end_ppq)
    elseif note.end_time ~= nil then
      end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, tonumber(note.end_time))
    elseif note.end_qn ~= nil then
      end_ppq = reaper.MIDI_GetPPQPosFromProjQN(take, tonumber(note.end_qn))
    elseif note.length_qn ~= nil then
      local base_qn = start_qn or (start_time and reaper.MIDI_GetProjQNFromPPQPos(take, start_ppq)) or 0
      end_ppq = reaper.MIDI_GetPPQPosFromProjQN(take, base_qn + tonumber(note.length_qn))
    elseif note.length_time ~= nil then
      local base_time = start_time or reaper.MIDI_GetProjTimeFromPPQPos(take, start_ppq)
      end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, base_time + tonumber(note.length_time))
    else
      end_ppq = start_ppq + 120
    end

    local pitch = tonumber(note.pitch or note.note or 60) or 60
    local velocity = tonumber(note.velocity or note.vel or 96) or 96
    local channel = tonumber(note.channel or 0) or 0
    local selected = note.selected == true
    local muted = note.muted == true
    local ok = reaper.MIDI_InsertNote(take, selected, muted, start_ppq, end_ppq, channel, pitch, velocity, true)
    if ok then
      inserted = inserted + 1
    end
  end
  reaper.MIDI_Sort(take)
  reaper.UpdateArrange()

  local _, note_count = reaper.MIDI_CountEvts(take)
  state.last_operation = "write_midi_notes"
  return true, {
    track = track_info(track, index),
    item = {
      id = item_guid(item),
      take = take_guid(take),
    },
    inserted = inserted,
    note_count = note_count,
  }
end

local function generate_drum_pattern(args)
  args = args or {}
  local bars = math.max(1, tonumber(args.bars or 4) or 4)
  local notes = {}
  for bar = 0, bars - 1 do
    local base = bar * 4
    notes[#notes + 1] = { start_qn = base + 0.0, end_qn = base + 0.25, pitch = 36, velocity = 110 }
    notes[#notes + 1] = { start_qn = base + 1.0, end_qn = base + 1.25, pitch = 38, velocity = 102 }
    notes[#notes + 1] = { start_qn = base + 2.0, end_qn = base + 2.25, pitch = 36, velocity = 108 }
    notes[#notes + 1] = { start_qn = base + 3.0, end_qn = base + 3.25, pitch = 38, velocity = 104 }
    notes[#notes + 1] = { start_qn = base + 0.5, end_qn = base + 0.6, pitch = 42, velocity = 82 }
    notes[#notes + 1] = { start_qn = base + 1.5, end_qn = base + 1.6, pitch = 42, velocity = 82 }
    notes[#notes + 1] = { start_qn = base + 2.5, end_qn = base + 2.6, pitch = 42, velocity = 82 }
    notes[#notes + 1] = { start_qn = base + 3.5, end_qn = base + 3.6, pitch = 42, velocity = 82 }
  end
  return true, {
    bars = bars,
    notes = notes,
    note_count = #notes,
  }
end

local function quantize_midi(args)
  args = args or {}
  local take, item, track, index = resolve_take(args)
  if not take then
    return false, { error = "midi_take_not_found", message = "No MIDI take available." }
  end

  local grid_qn = tonumber(args.grid_qn or args.grid or 0.25) or 0.25
  local _, note_count = reaper.MIDI_CountEvts(take)
  local quantized = 0
  reaper.MIDI_DisableSort(take)
  for i = 0, note_count - 1 do
    local ok, selected, muted, startppq, endppq, channel, pitch, velocity = reaper.MIDI_GetNote(take, i)
    if ok then
      local start_qn = reaper.MIDI_GetProjQNFromPPQPos(take, startppq)
      local end_qn = reaper.MIDI_GetProjQNFromPPQPos(take, endppq)
      local q_start = math.floor((start_qn / grid_qn) + 0.5) * grid_qn
      local q_end = math.floor((end_qn / grid_qn) + 0.5) * grid_qn
      local new_start = reaper.MIDI_GetPPQPosFromProjQN(take, q_start)
      local new_end = reaper.MIDI_GetPPQPosFromProjQN(take, math.max(q_end, q_start + grid_qn))
      reaper.MIDI_SetNote(take, i, selected, muted, new_start, new_end, channel, pitch, velocity, true)
      quantized = quantized + 1
    end
  end
  reaper.MIDI_Sort(take)
  reaper.UpdateArrange()
  state.last_operation = "quantize_midi"
  return true, {
    track = track_info(track, index),
    item = {
      id = item_guid(item),
      take = take_guid(take),
    },
    quantized = quantized,
    grid_qn = grid_qn,
  }
end

local function set_tempo(args)
  args = args or {}
  local bpm = tonumber(args.bpm or args.tempo)
  if not bpm then
    return false, { error = "missing_bpm", message = "Tempo value is required." }
  end

  local timepos = args.timepos ~= nil and tonumber(args.timepos) or reaper.GetCursorPosition()
  local measurepos = tonumber(args.measurepos or -1)
  local beatpos = tonumber(args.beatpos or -1)
  local timesig_num = tonumber(args.timesig_num or 4)
  local timesig_denom = tonumber(args.timesig_denom or 4)
  local lineartempo = args.lineartempo == true

  local ok = reaper.SetTempoTimeSigMarker(0, -1, timepos, measurepos, beatpos, bpm, timesig_num, timesig_denom, lineartempo)
  if not ok then
    return false, { error = "tempo_set_failed", message = "REAPER rejected the tempo change." }
  end
  state.last_operation = "set_tempo"
  return true, {
    tempo = reaper.Master_GetTempo(),
    requested = bpm,
    timepos = timepos,
  }
end

local function set_project_bpm(args)
  return set_tempo(args)
end

local function set_project_time_signature(args)
  args = args or {}
  local num = tonumber(args.num or args.timesig_num or 4) or 4
  local denom = tonumber(args.denom or args.timesig_denom or 4) or 4
  local bpm = tonumber(args.bpm or reaper.Master_GetTempo()) or reaper.Master_GetTempo()
  local ok = reaper.SetTempoTimeSigMarker(0, -1, reaper.GetCursorPosition(), -1, -1, bpm, num, denom, false)
  if not ok then
    return false, { error = "tempo_set_failed", message = "REAPER rejected the time signature change." }
  end
  state.last_operation = "set_project_time_signature"
  return true, {
    tempo = reaper.Master_GetTempo(),
    timesig_num = num,
    timesig_denom = denom,
  }
end

local function create_send(args)
  args = args or {}
  local source_track, source_index = resolve_track_selector({
    track_id = args.source_track_id,
    track_index = args.source_track_index,
    track_name = args.source_track_name,
    selected = args.source_selected,
  })
  if not source_track then
    return false, { error = "source_track_not_found", message = "Source track not found." }
  end

  local dest_track, dest_index = resolve_track_selector({
    track_id = args.dest_track_id,
    track_index = args.dest_track_index,
    track_name = args.dest_track_name,
    selected = args.dest_selected,
  })
  if not dest_track then
    return false, { error = "dest_track_not_found", message = "Destination track not found." }
  end

  local before = reaper.GetTrackNumSends(source_track, 0)
  local send_index = reaper.CreateTrackSend(source_track, dest_track)
  if send_index < 0 then
    return false, { error = "send_create_failed", message = "REAPER did not create the send." }
  end

  if args.volume ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_VOL", tonumber(args.volume))
  end
  if args.pan ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_PAN", tonumber(args.pan))
  end
  if args.send_mode ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "I_SENDMODE", tonumber(args.send_mode))
  end
  if args.src_chan ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "I_SRCCHAN", tonumber(args.src_chan))
  end
  if args.dst_chan ~= nil then
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "I_DSTCHAN", tonumber(args.dst_chan))
  end

  state.last_operation = "create_send"
  return true, {
    source_track = track_info(source_track, source_index),
    dest_track = track_info(dest_track, dest_index),
    send_index = send_index,
    send_count = reaper.GetTrackNumSends(source_track, 0),
    created = reaper.GetTrackNumSends(source_track, 0) >= before,
  }
end

local function create_sidechain_send(args)
  args = args or {}
  local payload = {
    source_track_id = args.source_track_id or args.source_track_ref,
    source_track_name = args.source_track_name,
    source_track_index = args.source_track_index,
    dest_track_id = args.dest_track_id or args.dest_track_ref,
    dest_track_name = args.dest_track_name,
    dest_track_index = args.dest_track_index,
    source_selected = args.source_selected,
    dest_selected = args.dest_selected,
    volume = args.volume,
    pan = args.pan,
    send_mode = args.send_mode or 3,
    src_chan = args.src_chan,
    dst_chan = args.dst_chan,
  }
  local ok, result = create_send(payload)
  if not ok then
    return false, result
  end
  state.last_operation = "create_sidechain_send"
  return true, result
end

local function route_track_to_bus(args)
  args = args or {}
  local source_track, source_index = resolve_track_selector({
    track_id = args.source_track_id,
    track_index = args.source_track_index,
    track_name = args.source_track_name,
    selected = args.source_selected,
    track = args.source_track == "last_created" and "last_created" or nil,
  })
  if not source_track then
    return false, { error = "source_track_not_found", message = "Source track not found." }
  end

  local bus_track, bus_index = resolve_track_selector({
    track_id = args.bus_track_id,
    track_index = args.bus_track_index,
    track_name = args.bus_track_name,
    selected = args.bus_selected,
  })

  if not bus_track and trim(args.bus_name or "") ~= "" then
    local ok, result = create_track({ name = args.bus_name, select_after = false })
    if not ok then
      return false, result
    end
    bus_track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    bus_index = reaper.GetMediaTrackInfo_Value(bus_track, "IP_TRACKNUMBER")
  end

  if not bus_track then
    return false, { error = "bus_track_not_found", message = "Bus track not found." }
  end

  local ok, result = create_send({
    source_track_id = track_guid(source_track),
    dest_track_id = track_guid(bus_track),
    volume = args.volume,
    pan = args.pan,
    send_mode = args.send_mode,
    src_chan = args.src_chan,
    dst_chan = args.dst_chan,
  })
  if not ok then
    return false, result
  end
  state.last_operation = "route_track_to_bus"
  return true, {
    source_track = track_info(source_track, source_index),
    bus_track = track_info(bus_track, bus_index),
    send = result,
  }
end

local function render_project(args)
  args = args or {}
  local command_id = tonumber(args.command_id or os.getenv("REAPER_RENDER_COMMAND_ID") or 42230)
  local ok = reaper.Main_OnCommand(command_id, 0)
  local stats = read_render_stats()
  if not ok and stats == "" then
    return false, { error = "render_failed", message = "Render command failed." }
  end
  state.last_operation = "render_project"
  state.last_render_stats = stats
  return true, {
    command_id = command_id,
    stats = stats,
  }
end

local function export_stems(args)
  return render_project(args)
end

local function play_transport()
  reaper.Main_OnCommand(1007, 0)
  state.last_operation = "play"
  return true, { playing = true }
end

local function stop_transport()
  reaper.Main_OnCommand(1016, 0)
  state.last_operation = "stop"
  return true, { stopped = true }
end

local function dry_run_plan(args)
  args = args or {}
  return true, {
    ok = true,
    plan = args.plan or args,
  }
end

local function undo_agent_plan()
  if reaper.Undo_DoUndo2 then
    local ok = reaper.Undo_DoUndo2(0)
    if ok then
      return true, { undone = true }
    end
  end
  if reaper.Main_OnCommand then
    reaper.Main_OnCommand(40029, 0)
    return true, { undone = true }
  end
  return false, { error = "undo_failed", message = "Undo failed." }
end

local function validate_tool_args(args)
  args = args or {}
  local tool_name = args.tool or args.tool_name
  if not tool_name or tool_name == "" then
    return false, { error = "missing_tool", message = "Tool name is required." }
  end
  for _, tool in ipairs(registry.tools) do
    if tool.name == tool_name then
      return true, { tool = tool_name, ok = true }
    end
  end
  return false, { error = "unknown_tool", message = "Tool is not in the registry." }
end

local function verify_project_state(args)
  args = args or {}
  local checks = args.checks or args
  local report = {
    snapshot = current_snapshot(),
    checks = {},
    ok = true,
  }

  local function add_check(name, passed, detail)
    report.checks[#report.checks + 1] = {
      name = name,
      ok = passed,
      detail = detail,
    }
    if not passed then
      report.ok = false
    end
  end

  local function each_check(value)
    if type(value) ~= "table" then
      return {}
    end
    if value[1] ~= nil then
      return value
    end
    return { value }
  end

  local function add_string_check(text)
    local normalized = trim(text or ""):lower()
    if normalized == "" then
      return
    end

    local track_name = normalized:match("^track%s+(.+)%s+exists$")
    if track_name then
      local ok, detail = verify_track_exists({ track_name = track_name })
      add_check("track_exists", ok, detail)
      return
    end

    local fx_name, target_track = normalized:match("^(.+)%s+inserted%s+on%s+(.+)$")
    if fx_name and target_track then
      local track, index = resolve_track_selector({ track_name = target_track })
      if not track then
        add_check("fx_inserted", false, { error = "track_not_found", message = "Track not found for FX check." })
        return
      end
      local fx_count = reaper.TrackFX_GetCount(track)
      for i = 0, fx_count - 1 do
        local ok, name = reaper.TrackFX_GetFXName(track, i)
        if ok and normalize(name):find(normalize(fx_name), 1, true) then
          add_check("fx_inserted", true, { track = track_info(track, index), fx = name })
          return
        end
      end
      add_check("fx_inserted", false, { error = "fx_not_found", message = "FX was not found on track." })
      return
    end

    if normalized:find("midi item", 1, true) and normalized:find("exist", 1, true) then
      local track = find_selected_track()
      if track then
        local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
        local ok, detail = verify_midi_item_created({ track_name = track_name or track_name })
        if ok then
          add_check("midi_item_created", ok, detail)
          return
        end
      end
    end
  end

  for _, item in ipairs(each_check(checks.track_exists)) do
    if type(item) == "string" then
      add_string_check(item)
    else
      local ok, detail = verify_track_exists(item)
      add_check("track_exists", ok, detail)
    end
  end
  for _, item in ipairs(each_check(checks.selected_track)) do
    if type(item) == "string" then
      add_string_check(item)
    else
      local ok, detail = verify_selected_track(item)
      add_check("selected_track", ok, detail)
    end
  end
  for _, item in ipairs(each_check(checks.fx_inserted)) do
    if type(item) == "string" then
      add_string_check(item)
    else
      local ok, detail = verify_fx_inserted(item)
      add_check("fx_inserted", ok, detail)
    end
  end
  for _, item in ipairs(each_check(checks.midi_item_created)) do
    if type(item) == "string" then
      add_string_check(item)
    else
      local ok, detail = verify_midi_item_created(item)
      add_check("midi_item_created", ok, detail)
    end
  end
  if checks.render_export_completed or checks.render_completed then
    local ok, detail = verify_render_completed()
    add_check("render_export_completed", ok, detail)
  end

  return report.ok, report
end

registry.tools = {
  {
    name = "get_project_state",
    description = "Build a short snapshot of the current REAPER project state.",
    json_schema = { type = "object", properties = {}, additionalProperties = false },
    example_user_phrase = "что сейчас открыто в проекте",
    execute = function(_args)
      return true, current_snapshot()
    end,
    possible_errors = {},
    result_format = "Project snapshot with tempo, selected track, tracks, regions, last created track, last operation.",
  },
  {
    name = "get_track_list",
    description = "Return a full list of tracks in the project.",
    json_schema = { type = "object", properties = {} },
    example_user_phrase = "покажи список дорожек",
    execute = function(_args)
      return true, { tracks = get_track_list() }
    end,
    possible_errors = {},
    result_format = "Track list.",
  },
  {
    name = "get_selected_tracks",
    description = "Return the currently selected track or tracks.",
    json_schema = { type = "object", properties = {} },
    example_user_phrase = "что выделено",
    execute = function(_args)
      return true, { tracks = get_selected_tracks() }
    end,
    possible_errors = {},
    result_format = "Selected tracks.",
  },
  {
    name = "get_last_created_track",
    description = "Return the most recently created track from agent state.",
    json_schema = { type = "object", properties = {} },
    example_user_phrase = "какой трек создали последним",
    execute = function(_args)
      return true, { track = get_last_created_track() }
    end,
    possible_errors = {},
    result_format = "Last created track info.",
  },
  {
    name = "resolve_track",
    description = "Resolve a track by id, name, index, or selection hints.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        selected = { type = "boolean" },
      },
    },
    example_user_phrase = "найди басовый трек",
    execute = resolve_track_public,
    possible_errors = { "track_not_found" },
    result_format = "Resolved track.",
  },
  {
    name = "create_track",
    description = "Create a new track and optionally set its name.",
    json_schema = {
      type = "object",
      properties = {
        name = { type = "string" },
        track_name = { type = "string" },
        select_after = { type = "boolean" },
      },
    },
    example_user_phrase = "создай трек вокал",
    execute = create_track,
    possible_errors = { "track_create_failed" },
    result_format = "Created track info and creation flag.",
  },
  {
    name = "find_track",
    description = "Find one or more tracks by id, name, index, or selection.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        selected = { type = "boolean" },
        query = { type = "string" },
      },
    },
    example_user_phrase = "найди трек бас",
    execute = find_track,
    possible_errors = {},
    result_format = "Single track or list of matches.",
  },
  {
    name = "select_track",
    description = "Select a track in REAPER.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
      },
    },
    example_user_phrase = "выдели трек вокал",
    execute = select_track,
    possible_errors = { "track_not_found", "selection_failed" },
    result_format = "Selected track info.",
  },
  {
    name = "rename_track",
    description = "Rename a track.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        new_name = { type = "string" },
        name = { type = "string" },
      },
      required = { "new_name" },
    },
    example_user_phrase = "переименуй трек в вокал лид",
    execute = rename_track,
    possible_errors = { "track_not_found", "missing_name" },
    result_format = "Track info and verified rename flag.",
  },
  {
    name = "delete_track",
    description = "Delete a track from the project.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
      },
    },
    example_user_phrase = "удали этот трек",
    execute = delete_track,
    possible_errors = { "track_not_found", "delete_failed" },
    result_format = "Deleted track info.",
  },
  {
    name = "set_track_volume",
    description = "Set a track volume.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        volume = { type = "number" },
        value = { type = "number" },
      },
      required = { "volume" },
    },
    example_user_phrase = "сделай трек громче",
    execute = set_track_volume,
    possible_errors = { "track_not_found", "missing_volume" },
    result_format = "Track volume updated.",
  },
  {
    name = "set_track_pan",
    description = "Set a track pan.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        pan = { type = "number" },
        value = { type = "number" },
      },
      required = { "pan" },
    },
    example_user_phrase = "смести трек влево",
    execute = set_track_pan,
    possible_errors = { "track_not_found", "missing_pan" },
    result_format = "Track pan updated.",
  },
  {
    name = "mute_track",
    description = "Mute or unmute a track.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        mute = { type = "boolean" },
      },
    },
    example_user_phrase = "заглуши трек",
    execute = mute_track,
    possible_errors = { "track_not_found" },
    result_format = "Track mute state.",
  },
  {
    name = "solo_track",
    description = "Solo or unsolo a track.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        solo = { type = "boolean" },
      },
    },
    example_user_phrase = "соло на треке",
    execute = solo_track,
    possible_errors = { "track_not_found" },
    result_format = "Track solo state.",
  },
  {
    name = "get_track_fx_list",
    description = "Return all FX on a track.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
      },
    },
    example_user_phrase = "покажи что стоит на басе",
    execute = get_track_fx_list,
    possible_errors = { "track_not_found" },
    result_format = "Track and FX list.",
  },
  {
    name = "insert_fx",
    description = "Insert an FX into a track using the local plugin catalog or exact REAPER FX name.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        fx_name = { type = "string" },
        fx_ref = { type = "string" },
        query = { type = "string" },
      },
      required = { "fx_name" },
    },
    example_user_phrase = "добавь компрессор на вокал",
    execute = insert_fx,
    possible_errors = { "track_not_found", "missing_fx_name", "fx_insert_failed" },
    result_format = "Inserted FX info and validation flag.",
  },
  {
    name = "remove_fx",
    description = "Remove an FX from a track by name.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        fx_name = { type = "string" },
        fx_ref = { type = "string" },
        query = { type = "string" },
      },
      required = { "fx_name" },
    },
    example_user_phrase = "удали компрессор с вокала",
    execute = remove_fx,
    possible_errors = { "track_not_found", "missing_fx_name", "fx_not_found", "fx_remove_failed" },
    result_format = "Removal result.",
  },
  {
    name = "bypass_fx",
    description = "Bypass or enable an FX on a track.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        fx_name = { type = "string" },
        fx_ref = { type = "string" },
        query = { type = "string" },
        enabled = { type = "boolean" },
      },
      required = { "fx_name" },
    },
    example_user_phrase = "обойди этот плагин",
    execute = bypass_fx,
    possible_errors = { "track_not_found", "missing_fx_name", "fx_not_found", "fx_bypass_failed" },
    result_format = "Bypass result.",
  },
  {
    name = "set_fx_preset",
    description = "Set a preset on an FX.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        fx_name = { type = "string" },
        fx_ref = { type = "string" },
        query = { type = "string" },
        preset = { type = "string" },
        preset_name = { type = "string" },
      },
      required = { "fx_name", "preset" },
    },
    example_user_phrase = "поставь пресет на Serum",
    execute = set_fx_preset,
    possible_errors = { "track_not_found", "missing_fx_or_preset", "fx_not_found", "preset_set_failed" },
    result_format = "Preset result.",
  },
  {
    name = "resolve_fx",
    description = "Resolve a user FX request to local catalog matches.",
    json_schema = {
      type = "object",
      properties = {
        query = { type = "string" },
        fx_name = { type = "string" },
        name = { type = "string" },
      },
      required = { "query" },
    },
    example_user_phrase = "что у нас есть из компрессоров",
    execute = resolve_fx,
    possible_errors = { "missing_query", "fx_not_found" },
    result_format = "Catalog matches and best match.",
  },
  {
    name = "generate_bassline",
    description = "Generate a bass MIDI pattern for a given number of bars.",
    json_schema = {
      type = "object",
      properties = {
        style = { type = "string" },
        bars = { type = "integer" },
        root = { type = "integer" },
      },
    },
    example_user_phrase = "сгенерируй агрессивный бас на 8 тактов",
    execute = generate_bassline,
    possible_errors = {},
    result_format = "Generated notes array.",
  },
  {
    name = "generate_chord_progression",
    description = "Generate a chord progression as MIDI note groups.",
    json_schema = {
      type = "object",
      properties = {
        key = { type = "string" },
        bars = { type = "integer" },
        root = { type = "integer" },
      },
    },
    example_user_phrase = "сделай аккорды на 4 такта в миноре",
    execute = generate_chord_progression,
    possible_errors = {},
    result_format = "Generated chord note array.",
  },
  {
    name = "create_midi_item",
    description = "Create a new MIDI item on a track.",
    json_schema = {
      type = "object",
      properties = {
        track_id = { type = "string" },
        track_ref = { type = "string" },
        track_name = { type = "string" },
        track_index = { type = "integer" },
        start_time = { type = "number" },
        end_time = { type = "number" },
        start = { type = "number" },
        finish = { type = "number" },
        length = { type = "number" },
        bars = { type = "number" },
        qn = { type = "boolean" },
        qn_mode = { type = "boolean" },
      },
      required = { "track_id" },
    },
    example_user_phrase = "создай миди-кусок на басу",
    execute = create_midi_item,
    possible_errors = { "track_not_found", "midi_item_create_failed", "midi_take_missing" },
    result_format = "Created MIDI item and take info.",
  },
  {
    name = "write_midi_notes",
    description = "Write MIDI notes into an existing MIDI take.",
    json_schema = {
      type = "object",
      properties = {
        take_id = { type = "string" },
        item_ref = { type = "string" },
        track_id = { type = "string" },
        track_ref = { type = "string" },
        notes = { type = "array" },
        notes_ref = { type = "string" },
      },
      required = { "notes" },
    },
    example_user_phrase = "запиши аккорды в миди",
    execute = write_midi_notes,
    possible_errors = { "midi_take_not_found", "missing_notes" },
    result_format = "Inserted note count and resulting note count.",
  },
  {
    name = "quantize_midi",
    description = "Quantize MIDI notes in the current or resolved take.",
    json_schema = {
      type = "object",
      properties = {
        take_id = { type = "string" },
        item_ref = { type = "string" },
        track_id = { type = "string" },
        track_ref = { type = "string" },
        grid_qn = { type = "number" },
        grid = { type = "number" },
      },
    },
    example_user_phrase = "квантизируй миди",
    execute = quantize_midi,
    possible_errors = { "midi_take_not_found" },
    result_format = "Quantize result.",
  },
  {
    name = "generate_drum_pattern",
    description = "Generate a basic drum pattern as MIDI notes.",
    json_schema = {
      type = "object",
      properties = {
        bars = { type = "integer" },
      },
    },
    example_user_phrase = "сделай драм-паттерн на 4 такта",
    execute = generate_drum_pattern,
    possible_errors = {},
    result_format = "Generated drum notes array.",
  },
  {
    name = "set_tempo",
    description = "Set the project tempo and optional time signature marker.",
    json_schema = {
      type = "object",
      properties = {
        bpm = { type = "number" },
        tempo = { type = "number" },
        timepos = { type = "number" },
        measurepos = { type = "number" },
        beatpos = { type = "number" },
        timesig_num = { type = "integer" },
        timesig_denom = { type = "integer" },
        lineartempo = { type = "boolean" },
      },
      required = { "bpm" },
    },
    example_user_phrase = "поставь темп 128",
    execute = set_tempo,
    possible_errors = { "missing_bpm", "tempo_set_failed" },
    result_format = "Requested tempo and actual project tempo.",
  },
  {
    name = "set_project_bpm",
    description = "Set the project BPM.",
    json_schema = {
      type = "object",
      properties = {
        bpm = { type = "number" },
        tempo = { type = "number" },
      },
      required = { "bpm" },
    },
    example_user_phrase = "поставь темп 170",
    execute = set_project_bpm,
    possible_errors = { "missing_bpm", "tempo_set_failed" },
    result_format = "Requested tempo and actual project tempo.",
  },
  {
    name = "set_project_time_signature",
    description = "Set the project time signature.",
    json_schema = {
      type = "object",
      properties = {
        num = { type = "integer" },
        denom = { type = "integer" },
        bpm = { type = "number" },
      },
    },
    example_user_phrase = "поставь размер 4 на 4",
    execute = set_project_time_signature,
    possible_errors = { "tempo_set_failed" },
    result_format = "Requested and actual time signature.",
  },
  {
    name = "create_send",
    description = "Create a send from one track to another.",
    json_schema = {
      type = "object",
      properties = {
        source_track_id = { type = "string" },
        source_track_ref = { type = "string" },
        source_track_name = { type = "string" },
        source_track_index = { type = "integer" },
        dest_track_id = { type = "string" },
        dest_track_ref = { type = "string" },
        dest_track_name = { type = "string" },
        dest_track_index = { type = "integer" },
      },
      required = { "source_track_id", "dest_track_id" },
    },
    example_user_phrase = "сделай посыл с вокала на реверб",
    execute = create_send,
    possible_errors = { "source_track_not_found", "dest_track_not_found", "send_create_failed" },
    result_format = "Source track, destination track, send index, send count.",
  },
  {
    name = "create_sidechain_send",
    description = "Create a sidechain send from one track to another.",
    json_schema = {
      type = "object",
      properties = {
        source_track_id = { type = "string" },
        source_track_ref = { type = "string" },
        source_track_name = { type = "string" },
        source_track_index = { type = "integer" },
        dest_track_id = { type = "string" },
        dest_track_ref = { type = "string" },
        dest_track_name = { type = "string" },
        dest_track_index = { type = "integer" },
      },
      required = { "source_track_id", "dest_track_id" },
    },
    example_user_phrase = "сделай сайдчейн с кика на бас",
    execute = create_sidechain_send,
    possible_errors = { "source_track_not_found", "dest_track_not_found", "send_create_failed" },
    result_format = "Sidechain send details.",
  },
  {
    name = "route_track_to_bus",
    description = "Route a track to a bus track, creating the bus if needed.",
    json_schema = {
      type = "object",
      properties = {
        source_track_id = { type = "string" },
        source_track_ref = { type = "string" },
        source_track_name = { type = "string" },
        source_track_index = { type = "integer" },
        bus_track_id = { type = "string" },
        bus_track_ref = { type = "string" },
        bus_track_name = { type = "string" },
        bus_track_index = { type = "integer" },
        bus_name = { type = "string" },
      },
      required = { "source_track_id" },
    },
    example_user_phrase = "закинь вокал в вокальный bus",
    execute = route_track_to_bus,
    possible_errors = { "source_track_not_found", "bus_track_not_found", "send_create_failed" },
    result_format = "Source track, bus track, and send details.",
  },
  {
    name = "play",
    description = "Start transport playback.",
    json_schema = { type = "object", properties = {} },
    example_user_phrase = "проиграй",
    execute = play_transport,
    possible_errors = {},
    result_format = "Transport started.",
  },
  {
    name = "stop",
    description = "Stop transport playback.",
    json_schema = { type = "object", properties = {} },
    example_user_phrase = "стоп",
    execute = stop_transport,
    possible_errors = {},
    result_format = "Transport stopped.",
  },
  {
    name = "dry_run_plan",
    description = "Validate a plan without executing it.",
    json_schema = { type = "object", properties = { plan = { type = "object" } } },
    example_user_phrase = "проверь план без выполнения",
    execute = dry_run_plan,
    possible_errors = {},
    result_format = "Dry-run validation result.",
  },
  {
    name = "undo_agent_plan",
    description = "Undo the last agent change.",
    json_schema = { type = "object", properties = {} },
    example_user_phrase = "отмени последнее действие",
    execute = undo_agent_plan,
    possible_errors = { "undo_failed" },
    result_format = "Undo status.",
  },
  {
    name = "validate_tool_args",
    description = "Validate tool arguments against registry presence.",
    json_schema = {
      type = "object",
      properties = {
        tool = { type = "string" },
        tool_name = { type = "string" },
      },
      required = { "tool" },
    },
    example_user_phrase = "проверь аргументы инструмента",
    execute = validate_tool_args,
    possible_errors = { "missing_tool", "unknown_tool" },
    result_format = "Tool validation status.",
  },
  {
    name = "verify_project_state",
    description = "Verify a planned project state change after execution.",
    json_schema = {
      type = "object",
      properties = {
        checks = { type = "object" },
        track_exists = { type = "object" },
        selected_track = { type = "object" },
        fx_inserted = { type = "object" },
        midi_item_created = { type = "object" },
        render_export_completed = { type = "boolean" },
        render_completed = { type = "boolean" },
      },
    },
    example_user_phrase = "проверь что трек создан и fx вставился",
    execute = verify_project_state,
    possible_errors = { "track_not_found", "selected_track_mismatch", "fx_not_found", "midi_item_missing", "render_not_completed" },
    result_format = "Boolean ok flag plus check details and snapshot.",
  },
  {
    name = "render_project",
    description = "Run the latest render command and capture render stats.",
    json_schema = {
      type = "object",
      properties = {
        command_id = { type = "integer" },
      },
    },
    example_user_phrase = "отрендери проект",
    execute = render_project,
    possible_errors = { "render_failed" },
    result_format = "Render command id and render stats summary.",
  },
  {
    name = "export_stems",
    description = "Export stems using the latest render command.",
    json_schema = {
      type = "object",
      properties = {
        command_id = { type = "integer" },
      },
    },
    example_user_phrase = "экспортируй стемы",
    execute = export_stems,
    possible_errors = { "render_failed" },
    result_format = "Render command id and render stats summary.",
  },
}

local extra_stub_tools = {
  stub_tool("create_project_snapshot", "history_versions", "Create a snapshot of the current project state.", "сделай снимок проекта"),
  stub_tool("restore_project_snapshot", "history_versions", "Restore a project snapshot.", "восстанови снимок"),
  stub_tool("list_project_snapshots", "history_versions", "List project snapshots.", "покажи снимки"),
  stub_tool("delete_project_snapshot", "history_versions", "Delete a project snapshot.", "удали снимок"),
  stub_tool("compare_project_snapshots", "history_versions", "Compare two project snapshots.", "сравни снимки"),
  stub_tool("create_mix_version", "history_versions", "Create a mix version.", "создай версию микса"),
  stub_tool("switch_mix_version", "history_versions", "Switch to a mix version.", "переключись на версию микса"),
  stub_tool("duplicate_project_version", "history_versions", "Duplicate a project version.", "дублируй версию проекта"),
  stub_tool("tag_project_version", "history_versions", "Add a tag to a project version.", "поставь тег версии"),
  stub_tool("add_version_note", "history_versions", "Add a note to a version.", "добавь заметку к версии"),
  stub_tool("get_version_notes", "history_versions", "Get version notes.", "покажи заметки версии"),
  stub_tool("rollback_to_before_agent_plan", "history_versions", "Rollback to the state before the last agent plan.", "откати до плана"),
  stub_tool("create_auto_backup_before_execution", "history_versions", "Create an automatic backup before execution.", "сделай автобэкап"),
  stub_tool("create_checkpoint_after_step", "history_versions", "Create a checkpoint after an important step.", "создай чекпоинт"),
  stub_tool("list_agent_checkpoints", "history_versions", "List agent checkpoints.", "покажи чекпоинты"),
  stub_tool("restore_agent_checkpoint", "history_versions", "Restore an agent checkpoint.", "восстанови чекпоинт"),
  stub_tool("resolve_pronoun_reference", "context_resolution", "Resolve a pronoun or reference from dialog context.", "разреши ссылку"),
  stub_tool("resolve_last_mentioned_track", "context_resolution", "Resolve the last mentioned track.", "последний упомянутый трек"),
  stub_tool("resolve_last_modified_track", "context_resolution", "Resolve the last modified track.", "последний изменённый трек"),
  stub_tool("resolve_last_created_fx", "context_resolution", "Resolve the last created FX.", "последний fx"),
  stub_tool("resolve_last_created_midi_item", "context_resolution", "Resolve the last created MIDI item.", "последний миди item"),
  stub_tool("resolve_last_created_audio_item", "context_resolution", "Resolve the last created audio item.", "последний audio item"),
  stub_tool("resolve_last_selected_object", "context_resolution", "Resolve the last selected object.", "последний выбранный объект"),
  stub_tool("resolve_target_from_dialog_context", "context_resolution", "Resolve a target from dialog history.", "определи цель из контекста"),
  stub_tool("save_dialog_reference", "context_resolution", "Save a dialog reference for later use.", "сохрани ссылку"),
  stub_tool("clear_dialog_reference", "context_resolution", "Clear dialog reference state.", "очисти ссылку"),
  stub_tool("get_dialog_context_state", "context_resolution", "Get dialog context state.", "состояние контекста"),
  stub_tool("ask_clarification_for_ambiguous_reference", "context_resolution", "Ask clarification for an ambiguous reference.", "уточни ссылку", "ask_user"),
  stub_tool("create_full_brazilian_phonk_demo", "recipes_extended", "Create a full Brazilian phonk demo template.", "сделай phonk demo", "use_script"),
  stub_tool("create_vocal_recording_template", "recipes_extended", "Create a vocal recording template.", "создай вокальную сессию", "use_script"),
  stub_tool("create_mix_prep_session", "recipes_extended", "Prepare a project for mixing.", "подготовь проект к сведению", "use_script"),
  stub_tool("create_mastering_session", "recipes_extended", "Create a mastering session.", "создай mastering session", "use_script"),
  stub_tool("create_client_delivery_package", "recipes_extended", "Create a client delivery package.", "собери delivery package", "use_script"),
  stub_tool("create_sample_pack_from_session", "recipes_extended", "Create a sample pack from a session.", "сделай sample pack", "use_script"),
  stub_tool("create_sidechain_system", "recipes_extended", "Create a sidechain system.", "сделай sidechain system", "use_script"),
  stub_tool("create_vocal_chop_instrument", "recipes_extended", "Create a vocal chop instrument.", "создай vocal chop instrument", "use_script"),
  stub_tool("create_clean_edit_version", "recipes_extended", "Create a clean edit version.", "сделай clean edit", "use_script"),
  stub_tool("create_social_media_snippet", "recipes_extended", "Create a social media snippet.", "сделай social snippet", "use_script"),
  stub_tool("create_stem_master_check", "recipes_extended", "Create a stem/master check.", "проверь стемы", "use_script"),
  stub_tool("show_plan_to_user", "chat_ui_agent", "Show the execution plan to the user.", "покажи план"),
  stub_tool("show_execution_progress", "chat_ui_agent", "Show execution progress.", "покажи прогресс"),
  stub_tool("show_failed_step", "chat_ui_agent", "Show the failed step.", "покажи ошибку шага"),
  stub_tool("show_repair_options", "chat_ui_agent", "Show repair options.", "покажи варианты исправления"),
  stub_tool("show_project_state_summary", "chat_ui_agent", "Show project state summary.", "покажи summary"),
}

for _, tool in ipairs(extra_stub_tools) do
  registry.tools[#registry.tools + 1] = tool
end

registry.recipes = {
  {
    name = "create_full_brazilian_phonk_demo",
    description = "Create a full Brazilian phonk demo with drums, cowbell, bass, sidechain, transitions, and intro/drop/outro flow.",
    steps = {
      { tool = "generate_bassline", args = { style = "aggressive brazilian phonk", bars = 8 } },
      { tool = "generate_drum_pattern", args = { bars = 8 } },
      { tool = "create_sidechain_system", args = {} },
      { tool = "create_phonk_texture", args = {} },
      { tool = "create_transition_between_regions", args = {} },
      { tool = "create_radio_edit_structure", args = {} },
    },
  },
  {
    name = "create_vocal_recording_template",
    description = "Create a vocal recording template with lead, doubles, backings, adlibs, and monitoring helpers.",
    steps = {
      { tool = "create_vocal_recording_session", args = {} },
      { tool = "create_talkback_track", args = {} },
      { tool = "create_cue_mix", args = {} },
      { tool = "create_headphone_mix", args = {} },
      { tool = "route_click_to_headphones", args = {} },
      { tool = "backup_recording_session", args = {} },
    },
  },
  {
    name = "create_mix_prep_session",
    description = "Prepare a project for mixing with organization, cleanup, and gain staging.",
    steps = {
      { tool = "show_project_state_summary", args = {} },
      { tool = "create_auto_backup_before_execution", args = {} },
      { tool = "create_checkpoint_after_step", args = {} },
      { tool = "show_last_changes", args = {} },
    },
  },
  {
    name = "create_client_delivery_package",
    description = "Create a delivery package with export variants and zip packaging.",
    steps = {
      { tool = "prepare_stems_for_client", args = {} },
      { tool = "prepare_instrumental_export", args = {} },
      { tool = "prepare_acapella_export", args = {} },
      { tool = "zip_delivery_package", args = {} },
      { tool = "verify_delivery_files", args = {} },
    },
  },
  {
    name = "create_sample_pack_from_session",
    description = "Create a sample pack and loop pack from the current session.",
    steps = {
      { tool = "create_loop_pack_from_project", args = {} },
      { tool = "export_selected_items_as_loops", args = {} },
      { tool = "categorize_loops_by_type", args = {} },
      { tool = "create_sample_pack_folder_structure", args = {} },
      { tool = "verify_loop_seamlessness", args = {} },
    },
  },
  {
    name = "create_stem_master_check",
    description = "Create a stem and master quality check workflow.",
    steps = {
      { tool = "measure_integrated_lufs", args = {} },
      { tool = "measure_true_peak", args = {} },
      { tool = "check_headroom", args = {} },
      { tool = "create_master_quality_report", args = {} },
    },
  },
  {
    name = "create_brazilian_phonk_project",
    description = "Create a basic Brazilian phonk template with drums, bass, sidechain, and arrangement markers.",
    steps = {
      { tool = "set_project_bpm", args = { bpm = 170 } },
      { tool = "set_project_time_signature", args = { num = 4, denom = 4 } },
      { tool = "create_track", args = { name = "Kick" } },
      { tool = "create_track", args = { name = "Bass" } },
      { tool = "create_track", args = { name = "Cowbell" } },
      { tool = "resolve_fx", args = { query = "Serum" } },
      { tool = "insert_fx", args = { track_name = "Bass", fx_name = "VST3i: Serum (Xfer Records)" } },
      { tool = "create_midi_item", args = { track_name = "Bass", bars = 8 } },
      { tool = "generate_bassline", args = { style = "aggressive brazilian phonk", bars = 8 } },
      { tool = "write_midi_notes", args = { track_name = "Bass", notes = {
        { start_qn = 0, end_qn = 0.5, pitch = 36, velocity = 100 },
      } } },
      { tool = "create_sidechain_send", args = { source_track_name = "Kick", dest_track_name = "Bass" } },
      { tool = "verify_project_state", args = { checks = { track_exists = { { track_name = "Kick" }, { track_name = "Bass" }, { track_name = "Cowbell" } } } } },
    },
  },
  {
    name = "create_instrument_track",
    description = "Create a track, insert an instrument, create MIDI item, and prepare for writing notes.",
    steps = {
      { tool = "create_track", args = { name = "Instrument" } },
      { tool = "insert_fx", args = { fx_name = "ReaSynth" } },
      { tool = "create_midi_item", args = { start_time = 0, end_time = 4 } },
    },
  },
  {
    name = "create_drum_bus",
    description = "Create a drum bus and route the selected drum tracks into it.",
    steps = {
      { tool = "create_track", args = { name = "Drum Bus" } },
      { tool = "select_track", args = { track_name = "Drum Bus" } },
    },
  },
  {
    name = "add_sidechain_compression",
    description = "Create a sidechain send and insert a compressor on the receiving track.",
    steps = {
      { tool = "create_send", args = { source_track_name = "Kick", dest_track_name = "Bass" } },
      { tool = "insert_fx", args = { track_name = "Bass", fx_name = "ReaComp" } },
    },
  },
  {
    name = "create_midi_pattern",
    description = "Create a MIDI item and write a short pattern.",
    steps = {
      { tool = "create_midi_item", args = { start_time = 0, end_time = 4 } },
      { tool = "write_midi_notes", args = {
        notes = {
          { start_qn = 0, end_qn = 1, pitch = 36, velocity = 100 },
          { start_qn = 1, end_qn = 2, pitch = 38, velocity = 100 },
          { start_qn = 2, end_qn = 3, pitch = 42, velocity = 100 },
          { start_qn = 3, end_qn = 4, pitch = 38, velocity = 100 },
        },
      } },
    },
  },
  {
    name = "export_stems",
    description = "Prepare render/export and verify the render completed.",
    steps = {
      { tool = "render_project", args = {} },
      { tool = "verify_project_state", args = { checks = { render_export_completed = true } } },
    },
  },
  {
    name = "clean_project",
    description = "Create a validation pass that the target tracks and FX exist before finishing cleanup.",
    steps = {
      { tool = "get_project_state", args = {} },
      { tool = "verify_project_state", args = { checks = {} } },
    },
  },
}

function registry.get_project_state()
  return current_snapshot()
end

function registry.get_tool_metadata()
  local tools = {}
  for _, tool in ipairs(registry.tools) do
    tools[#tools + 1] = {
      name = tool.name,
      category = tool_category(tool.name),
      description = tool.description,
      json_schema = tool.json_schema,
      example_user_phrase = tool.example_user_phrase,
      possible_errors = tool.possible_errors,
      result_format = tool.result_format,
      implementation_status = tool.implementation_status or "implemented",
      fallback = tool.fallback,
    }
  end
  return tools
end

function registry.get_recipe_metadata()
  local recipes = {}
  for _, recipe in ipairs(registry.recipes) do
    recipes[#recipes + 1] = {
      name = recipe.name,
      description = recipe.description,
      steps = recipe.steps,
    }
  end
  return recipes
end

function registry.get_plugin_catalog()
  return plugin_catalog
end

function registry.resolve_plugin(query)
  return find_fx_in_catalog(query)
end

function registry.execute_tool(name, args)
  args = args or {}
  for _, tool in ipairs(registry.tools) do
    if tool.name == name then
      local ok, result = tool.execute(args)
      if ok then
        state.last_error = nil
        return {
          ok = true,
          tool = name,
          result = result,
          error = nil,
        }
      end
      state.last_error = result
      return {
        ok = false,
        tool = name,
        result = nil,
        error = result,
      }
    end
  end
  return {
    ok = false,
    tool = name,
    result = nil,
    error = {
      error = "unknown_tool",
      message = "Tool is not in the registry.",
    },
  }
end

function registry.is_allowed_tool(name)
  for _, tool in ipairs(registry.tools) do
    if tool.name == name then
      return true
    end
  end
  return false
end

function registry.expand_recipe(name, args)
  args = args or {}
  for _, recipe in ipairs(registry.recipes) do
    if recipe.name == name then
      local steps = {}
      for _, step in ipairs(recipe.steps) do
        local merged_args = {}
        for key, value in pairs(step.args or {}) do
          merged_args[key] = value
        end
        for key, value in pairs(args) do
          if merged_args[key] == nil then
            merged_args[key] = value
          end
        end
        steps[#steps + 1] = { tool = step.tool, args = merged_args }
      end
      return steps
    end
  end
  return nil
end

function registry.build_plan_context()
  return {
    tool_registry = registry.get_tool_metadata(),
    recipes = registry.get_recipe_metadata(),
    plugin_catalog = registry.get_plugin_catalog(),
    project_state = registry.get_project_state(),
    last_operation = state.last_operation,
    last_created_track = state.last_created_track,
  }
end

function registry.set_last_operation(label)
  state.last_operation = label or state.last_operation
end

function registry.record_render_stats(stats)
  state.last_render_stats = stats or ""
end

function registry.get_state()
  return state
end

return registry
