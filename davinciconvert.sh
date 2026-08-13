#!/bin/bash

# ==============================================================================
# DavinciConvert - Smart Media Transcoder for DaVinci Resolve on Linux
# 
# Features:
#   1. State-Machine Decision Engine with 1-pass FFprobe metadata extraction.
#   2. Converts any video/audio for DaVinci Resolve Free on Linux (ProRes 422 + PCM audio).
#   3. Converts DaVinci exports back to H.264/AAC MP4 with yuv420p for Social Media.
#   4. Dynamic resolution, FPS, and aspect ratio analysis (vertical 9:16 & widescreen).
#   5. Hardware auto-detection (NVIDIA NVENC, Intel QSV, AMD VAAPI) with CPU fallback.
#   6. Universal Matrix Protection: Bypasses redundant re-encoding & auto-routes misplaced files across all 4 folders.
#   7. Collision-Safe File Movement: Never overwrites files with duplicate names during auto-routing.
#   8. Multi-Audio Track Preservation: Maps all OBS audio streams (Microphone, Game, Discord) independently.
#   9. Quarantine System: Automatically moves damaged/unreadable files to CORRUPTED/ folder.
#  10. Date-Based Archiving (--archive / -a): Moves original raw files to ARCHIV/YYYY-MM-DD/.
#  11. Linux Desktop Launcher (--install-desktop): Installs DavinciConvert to GNOME / Fedora Application Grid.
#  12. Real-time folder watching mode (--watch / -w).
# ==============================================================================

# Always change working directory strictly to the directory where this script is physically located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR" || exit 1

# Auto-launch terminal window if double-clicked from file manager
if [ -z "$DAVINCICONVERT_HEADLESS" ] && [ ! -t 0 ] && [ ! -t 1 ] && [ -n "$DISPLAY" -o -n "$WAYLAND_DISPLAY" ]; then
    for term in gnome-terminal konsole xfce4-terminal kitty alacritty xterm x-terminal-emulator; do
        if command -v $term >/dev/null 2>&1; then
            case $term in
                gnome-terminal) exec gnome-terminal -- title "DavinciConvert" -- bash -c "DAVINCICONVERT_HEADLESS=1 '$0' $*; echo ''; read -p 'Press Enter to exit...'" ;;
                konsole) exec konsole --title "DavinciConvert" -e bash -c "DAVINCICONVERT_HEADLESS=1 '$0' $*; echo ''; read -p 'Press Enter to exit...'" ;;
                xfce4-terminal) exec xfce4-terminal -T "DavinciConvert" -e "bash -c \"DAVINCICONVERT_HEADLESS=1 '$0' $*; echo ''; read -p 'Press Enter to exit...'\"" ;;
                *) exec $term -e bash -c "DAVINCICONVERT_HEADLESS=1 '$0' $*; echo ''; read -p 'Press Enter to exit...'" ;;
            esac
            exit 0
        fi
    done
fi

# ANSI Color Code System for Terminal UI
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_CYAN="\033[36m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_MAGENTA="\033[35m"
C_RED="\033[31m"
C_WHITE="\033[37m"

IMPORT_DIR="$DIR/1_IMPORT"
DAVINCI_DIR="$DIR/1_PRORES_DAVINCI"
EXPORT_DIR="$DIR/2_EXPORT"
FINAL_DIR="$DIR/3_FINAL_SOCIAL"
ARCHIVE_DIR="$DIR/ARCHIV"
CORRUPT_DIR="$DIR/CORRUPTED"

# Default Quality & Processing Settings
PRORES_PROFILE_OVERRIDE=""
CPU_PRESET="superfast"
AUDIO_BITRATE="320k"
ENABLE_ARCHIVE=0
WATCH_MODE=0

# Parse optional CLI flags
show_help() {
    echo -e "${C_CYAN}${C_BOLD}DavinciConvert v1.0.0 - Usage:${C_RESET}"
    echo -e "  ./davinciconvert.sh [OPTIONS]"
    echo ""
    echo -e "${C_BOLD}Options:${C_RESET}"
    echo -e "  -w, --watch            Watch directory continuously for new files"
    echo -e "  -a, --archive          Move original raw files to ARCHIV/ folder instead of deleting"
    echo -e "  -q, --quality <lt|std|hq>  Set ProRes quality profile (lt = ProRes LT, std = Standard, hq = ProRes HQ)"
    echo -e "  -p, --preset <preset>   Set CPU encoding speed (ultrafast, superfast, fast, medium, slow)"
    echo -e "  --install-desktop      Install Linux Desktop Launcher into application grid"
    echo -e "  -h, --help             Show this help menu"
    exit 0
}

install_desktop_launcher() {
    local apps_dir="$HOME/.local/share/applications"
    mkdir -p "$apps_dir"
    local desktop_file="$apps_dir/DavinciConvert.desktop"

    cat <<EOF > "$desktop_file"
[Desktop Entry]
Type=Application
Name=DavinciConvert
Comment=Smart Media Transcoder for DaVinci Resolve Free on Linux
Exec=bash -c '"$DIR/davinciconvert.sh"; echo ""; read -p "Press Enter to exit..."'
Icon=video-x-generic
Terminal=true
Categories=AudioVideo;Video;AudioVideoEditing;
Keywords=davinci;convert;ffmpeg;prores;transcode;
EOF

    chmod +x "$desktop_file"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps_dir" >/dev/null 2>&1
    fi
    echo -e "${C_GREEN}${C_BOLD}[✅ DONE]${C_RESET} Desktop launcher installed successfully to: $desktop_file"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--watch) WATCH_MODE=1; shift ;;
        -a|--archive) ENABLE_ARCHIVE=1; shift ;;
        -q|--quality)
            case "$2" in
                lt) PRORES_PROFILE_OVERRIDE=1 ;;
                std|standard) PRORES_PROFILE_OVERRIDE=2 ;;
                hq) PRORES_PROFILE_OVERRIDE=3 ;;
            esac
            shift 2 ;;
        -p|--preset) CPU_PRESET="$2"; shift 2 ;;
        --install-desktop) install_desktop_launcher ;;
        -h|--help) show_help ;;
        *) shift ;;
    esac
done

# Create directories if they do not exist
mkdir -p "$IMPORT_DIR" "$DAVINCI_DIR" "$EXPORT_DIR" "$FINAL_DIR"
[ $ENABLE_ARCHIVE -eq 1 ] && mkdir -p "$ARCHIVE_DIR"

send_notification() {
    local title="$1"
    local msg="$2"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i video-x-generic "$title" "$msg" 2>/dev/null &
    fi
}

detect_best_encoder() {
    if ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=128x128 -c:v h264_nvenc -f null - >/dev/null 2>&1; then
        echo "NVENC"
        return
    fi
    if ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=128x128 -c:v h264_qsv -f null - >/dev/null 2>&1; then
        echo "QSV"
        return
    fi
    if [ -e "/dev/dri/renderD128" ] && ffmpeg -hide_banner -loglevel error -vaapi_device /dev/dri/renderD128 -y -f lavfi -i testsrc=duration=1:size=128x128 -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - >/dev/null 2>&1; then
        echo "VAAPI"
        return
    fi
    echo "CPU"
}

ENCODER_MODE=$(detect_best_encoder)

# Display Header Banner
echo -e "${C_CYAN}${C_BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_BOLD}🎬 DavinciConvert v1.0.0${C_RESET} ${C_DIM}| Smart Media Transcoder for Linux${C_RESET}             ${C_CYAN}${C_BOLD}║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╠════════════════════════════════════════════════════════════════════════════════╣${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Working Directory   :${C_RESET} ${C_WHITE}$DIR${C_RESET}"
if [ "$ENCODER_MODE" == "CPU" ]; then
    echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Export Acceleration :${C_RESET} ${C_YELLOW}${C_BOLD}CPU (Multi-threaded Fallback - $CPU_PRESET)${C_RESET}"
else
    echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Export Acceleration :${C_RESET} ${C_GREEN}${C_BOLD}Hardware ($ENCODER_MODE GPU Acceleration)${C_RESET}"
fi
[ $ENABLE_ARCHIVE -eq 1 ] && echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Safety Archiving    :${C_RESET} ${C_GREEN}${C_BOLD}ENABLED (Moving originals to ARCHIV/)${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${C_RESET}"

# Single-pass FFprobe metadata probe function directly into parent shell
probe_media() {
    local f="$1"
    PROBE_V_CODEC=""
    PROBE_A_CODEC=""
    PROBE_PIX_FMT=""
    PROBE_WIDTH=0
    PROBE_HEIGHT=0
    PROBE_FPS=30
    PROBE_HAS_VIDEO=0
    PROBE_HAS_AUDIO=0
    PROBE_IS_ATTACHED_PIC=0

    [ ! -f "$f" ] && return 1

    local v_info
    v_info=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,pix_fmt,r_frame_rate -show_entries stream_disposition=attached_pic -of csv=p=0 "$f" 2>/dev/null | head -n1)
    
    if [ -n "$v_info" ]; then
        PROBE_HAS_VIDEO=1
        IFS=',' read -r PROBE_V_CODEC PROBE_WIDTH PROBE_HEIGHT PROBE_PIX_FMT raw_fps PROBE_IS_ATTACHED_PIC <<< "$v_info"
        PROBE_WIDTH=${PROBE_WIDTH:-0}
        PROBE_HEIGHT=${PROBE_HEIGHT:-0}
        PROBE_IS_ATTACHED_PIC=${PROBE_IS_ATTACHED_PIC:-0}
        if [ -n "$raw_fps" ]; then
            PROBE_FPS=$(awk -F'/' '{if ($2>0) print int($1/$2); else print int($1)}' <<< "$raw_fps")
        fi
    fi

    local a_info
    a_info=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null | head -n1)
    if [ -n "$a_info" ]; then
        PROBE_HAS_AUDIO=1
        PROBE_A_CODEC=$(cut -d',' -f1 <<< "$a_info")
    fi

    return 0
}

# Centralized State Machine Classifier directly setting PROBE_STATE in parent shell
classify_file() {
    local f="$1"
    PROBE_STATE="STATE_INVALID"
    
    probe_media "$f" || return 1

    local filename
    filename=$(basename -- "$f")
    local clean_filename
    clean_filename=$(sed -E 's/ \([0-9]+\)$//' <<< "$filename")
    local ext="${clean_filename##*.}"
    local ext_lower
    ext_lower=$(tr '[:upper:]' '[:lower:]' <<< "$ext")

    local is_audio_ext=0
    if [[ "$ext_lower" =~ ^(mp3|wav|flac|aac|m4a|ogg|opus|wma|aiff|ac3)$ ]]; then
        is_audio_ext=1
    fi

    local is_video_file=0
    if [ "${PROBE_HAS_VIDEO:-0}" -gt 0 ] && [ "${PROBE_IS_ATTACHED_PIC:-0}" -eq 0 ] && [ $is_audio_ext -eq 0 ]; then
        is_video_file=1
    fi

    # 1. Test STATE_DAVINCI_READY
    if [ $is_video_file -eq 1 ]; then
        if [[ "$PROBE_V_CODEC" =~ ^(prores|dnxhd|dnxhr|cineform|rawvideo|mjpeg)$ ]] && [[ "$PROBE_A_CODEC" == pcm_* || "${PROBE_HAS_AUDIO:-0}" -eq 0 ]]; then
            PROBE_STATE="STATE_DAVINCI_READY"
            return 0
        fi
    elif [ $is_audio_ext -eq 1 ]; then
        if [[ "$PROBE_A_CODEC" == pcm_* ]] && [ "$ext_lower" == "wav" ]; then
            PROBE_STATE="STATE_DAVINCI_READY"
            return 0
        fi
    fi

    # 2. Test STATE_SOCIAL_READY
    if [ $is_video_file -eq 1 ]; then
        if [ "$PROBE_V_CODEC" == "h264" ] && [ "$PROBE_PIX_FMT" == "yuv420p" ] && [[ "$PROBE_A_CODEC" == "aac" || "$PROBE_A_CODEC" == "mp3" || "${PROBE_HAS_AUDIO:-0}" -eq 0 ]] && [ "$ext_lower" == "mp4" ]; then
            PROBE_STATE="STATE_SOCIAL_READY"
            return 0
        fi
    elif [ $is_audio_ext -eq 1 ]; then
        if [ "$PROBE_A_CODEC" == "mp3" ] && [ "$ext_lower" == "mp3" ]; then
            PROBE_STATE="STATE_SOCIAL_READY"
            return 0
        fi
    fi

    # 3. Test STATE_RAW_IMPORT (Any raw video/audio requiring conversion)
    if [ $is_video_file -eq 1 ] || [ "${PROBE_HAS_AUDIO:-0}" -gt 0 ] || [ $is_audio_ext -eq 1 ]; then
        PROBE_STATE="STATE_RAW_IMPORT"
        return 0
    fi

    PROBE_STATE="STATE_INVALID"
    return 1
}

# Generate unique path during filename collision
get_unique_path() {
    local target="$1"
    if [ -f "$target" ]; then
        local dir
        dir=$(dirname -- "$target")
        local fn
        fn=$(basename -- "$target")
        local name="${fn%.*}"
        local ext="${fn##*.}"
        local counter=1
        while [ -f "$dir/${name}_${counter}.${ext}" ]; do
            ((counter++))
        done
        echo "$dir/${name}_${counter}.${ext}"
    else
        echo "$target"
    fi
}

# Collision-safe move function to prevent overwriting files with identical names
safe_move() {
    local src="$1"
    local dst_dir="$2"
    
    mkdir -p "$dst_dir"
    local fn
    fn=$(basename -- "$src")
    
    local target="$dst_dir/$fn"
    if [ -f "$target" ] && [ "$src" != "$target" ]; then
        target=$(get_unique_path "$target")
    fi

    [ "$src" != "$target" ] && mv "$src" "$target"
}

run_ffmpeg_with_progress() {
    local input="$1"
    local title="$2"
    local output_file="$3"
    shift 3

    rm -f "$output_file"

    # Native FFmpeg execution with real-time progress stats in terminal
    ffmpeg -hide_banner -loglevel error -stats "$@"
    local res=$?

    if [ $res -eq 0 ] && [ -s "$output_file" ]; then
        return 0
    else
        rm -f "$output_file"
        return 1
    fi
}

handle_original_file() {
    local src_file="$1"
    if [ $ENABLE_ARCHIVE -eq 1 ]; then
        local today=$(date +%Y-%m-%d)
        local today_archive="$ARCHIVE_DIR/$today"
        safe_move "$src_file" "$today_archive"
    else
        rm -f "$src_file"
    fi
}

process_files() {
    shopt -s nullglob
    local total_processed=0
    local import_processed=0
    local export_processed=0
    declare -A failed_files

    while true; do
        local pass_processed=0

        # ----------------------------------------------------
        # 0A. MATRIX CHECK: MISPLACED FILES IN 3_FINAL_SOCIAL
        # ----------------------------------------------------
        for file in "$FINAL_DIR"/*; do
            [ -f "$file" ] || continue
            [ -n "${failed_files["$file"]}" ] && continue

            filename=$(basename -- "$file")
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            classify_file "$file"
            if [ "$PROBE_STATE" != "STATE_SOCIAL_READY" ]; then
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}[🔀 SMART REROUTE]${C_RESET} '$filename' placed in 3_FINAL_SOCIAL by mistake. Moving to 2_EXPORT for social media encoding..."
                safe_move "$file" "$EXPORT_DIR"
                ((pass_processed++))
                ((total_processed++))
                continue
            fi
        done

        # ----------------------------------------------------
        # 0B. MATRIX CHECK: UNCONVERTED FILES IN 1_PRORES_DAVINCI
        # ----------------------------------------------------
        for file in "$DAVINCI_DIR"/*; do
            [ -f "$file" ] || continue
            [ -n "${failed_files["$file"]}" ] && continue

            filename=$(basename -- "$file")
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            classify_file "$file"
            if [ "$PROBE_STATE" == "STATE_SOCIAL_READY" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ SMART BYPASS]${C_RESET} '$filename' is ALREADY converted for Social Media! Moving to 3_FINAL_SOCIAL..."
                safe_move "$file" "$FINAL_DIR"
                ((pass_processed++))
                ((total_processed++))
                continue
            elif [ "$PROBE_STATE" != "STATE_DAVINCI_READY" ]; then
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}[🔀 SMART REROUTE]${C_RESET} '$filename' placed in 1_PRORES_DAVINCI by mistake. Moving to 1_IMPORT..."
                safe_move "$file" "$IMPORT_DIR"
                ((pass_processed++))
                ((total_processed++))
                continue
            fi
        done

        # ----------------------------------------------------
        # 1. PROCESS 1_IMPORT FOLDER (Preparation FOR DaVinci)
        # ----------------------------------------------------
        for file in "$IMPORT_DIR"/*; do
            [ -f "$file" ] || continue
            [ -n "${failed_files["$file"]}" ] && continue

            filename=$(basename -- "$file")
            clean_filename=$(sed -E 's/ \([0-9]+\)$//' <<< "$filename")
            name="${filename%.*}"
            base_name=$(sed -E 's/_davinci$//; s/_social$//' <<< "$name")
            ext="${clean_filename##*.}"
            ext_lower=$(tr '[:upper:]' '[:lower:]' <<< "$ext")

            # Skip hidden & temporary downloading files (.part, .crdownload, .tmp, .ytdl...)
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            classify_file "$file"

            if [ "$PROBE_STATE" == "STATE_DAVINCI_READY" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ SMART BYPASS]${C_RESET} '$filename' is ALREADY in ProRes/DNxHD or WAV PCM! Moving..."
                safe_move "$file" "$DAVINCI_DIR"
                ((pass_processed++))
                ((total_processed++))
                ((import_processed++))
                continue
            elif [ "$PROBE_STATE" == "STATE_INVALID" ]; then
                echo ""
                echo -e "${C_RED}${C_BOLD}[🛑 CORRUPTED FILE]${C_RESET} '$filename' is corrupted or unreadable. Moving to CORRUPTED/..."
                safe_move "$file" "$CORRUPT_DIR"
                ((pass_processed++))
                continue
            fi

            # All files placed in 1_IMPORT (raw videos & raw audio MP3/FLAC) are converted for DaVinci
            if [ "${PROBE_HAS_VIDEO:-0}" -gt 0 ] && [ "${PROBE_IS_ATTACHED_PIC:-0}" -eq 0 ]; then
                max_dim=${PROBE_WIDTH:-0}
                [ "${PROBE_HEIGHT:-0}" -gt "$max_dim" ] && max_dim=$PROBE_HEIGHT

                prores_prof=1
                label="1080p"
                if [ "$max_dim" -ge 3800 ]; then
                    prores_prof=2
                    label="4K (2160p)"
                elif [ "$max_dim" -ge 2400 ]; then
                    label="2K (1440p)"
                elif [ "$max_dim" -ge 1800 ]; then
                    label="Full HD (1080p)"
                else
                    label="HD (720p)"
                fi

                [ -n "$PRORES_PROFILE_OVERRIDE" ] && prores_prof="$PRORES_PROFILE_OVERRIDE"

                echo ""
                echo -e "${C_YELLOW}${C_BOLD}┌─ [ 📥 IMPORT -> DaVinci Prep ] ───────────────────────────────────────────┐${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_BOLD}File:${C_RESET}        $filename"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Format:${C_RESET}      ${PROBE_WIDTH}x${PROBE_HEIGHT} ($label @ ${PROBE_FPS}FPS | Audio Tracks: $PROBE_HAS_AUDIO)"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}Apple ProRes 422 MOV + Uncompressed PCM Audio${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Encoder:${C_RESET}     ${C_YELLOW}${C_BOLD}CPU Multi-threading (ProRes is CPU master codec)${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mov="$DAVINCI_DIR/${base_name}_davinci.mov"
                out_mov=$(get_unique_path "$out_mov")

                run_ffmpeg_with_progress "$file" "DaVinci Prep: $filename" "$out_mov" \
                    -threads 0 \
                    -y -i "$file" \
                    -map "0:v?" -map "0:a?" -map_chapters 0 \
                    -c:v prores_ks -profile:v "$prores_prof" \
                    -c:a pcm_s16le "$out_mov"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_mov" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 1_PRORES_DAVINCI/$(basename -- "$out_mov")"
                    ((pass_processed++))
                    ((total_processed++))
                    ((import_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of video '$filename' failed."
                    failed_files["$file"]=1
                fi

            else
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}┌─ [ 🎵 IMPORT Audio -> DaVinci Prep ] ─────────────────────────────────────┐${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_BOLD}File:${C_RESET}        $filename"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}WAV / Uncompressed PCM 48kHz${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Encoder:${C_RESET}     ${C_YELLOW}${C_BOLD}CPU (Uncompressed PCM Audio)${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_wav="$DAVINCI_DIR/${base_name}_davinci.wav"
                out_wav=$(get_unique_path "$out_wav")

                run_ffmpeg_with_progress "$file" "DaVinci Audio Prep: $filename" "$out_wav" \
                    -vn -y -i "$file" \
                    -c:a pcm_s16le -ar 48000 "$out_wav"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_wav" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 1_PRORES_DAVINCI/$(basename -- "$out_wav")"
                    ((pass_processed++))
                    ((total_processed++))
                    ((import_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of audio '$filename' failed."
                    failed_files["$file"]=1
                fi
            fi
        done

        # ----------------------------------------------------
        # 2. PROCESS 2_EXPORT FOLDER (Preparation FROM DaVinci for Social Media)
        # ----------------------------------------------------
        for file in "$EXPORT_DIR"/*; do
            [ -f "$file" ] || continue
            [ -n "${failed_files["$file"]}" ] && continue

            filename=$(basename -- "$file")
            clean_filename=$(sed -E 's/ \([0-9]+\)$//' <<< "$filename")
            name="${filename%.*}"
            base_name=$(sed -E 's/_davinci$//; s/_social$//' <<< "$name")
            ext="${clean_filename##*.}"
            ext_lower=$(tr '[:upper:]' '[:lower:]' <<< "$ext")

            # Skip hidden & temporary downloading files
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            classify_file "$file"

            if [ "$PROBE_STATE" == "STATE_SOCIAL_READY" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ SMART BYPASS]${C_RESET} '$filename' is ALREADY converted for Social Media! Moving to 3_FINAL_SOCIAL..."
                safe_move "$file" "$FINAL_DIR"
                ((pass_processed++))
                ((total_processed++))
                ((export_processed++))
                continue
            elif [ "$PROBE_STATE" == "STATE_INVALID" ]; then
                echo ""
                echo -e "${C_RED}${C_BOLD}[🛑 CORRUPTED FILE]${C_RESET} '$filename' is corrupted or unreadable. Moving to CORRUPTED/..."
                safe_move "$file" "$CORRUPT_DIR"
                ((pass_processed++))
                continue
            fi

            # Any file in 2_EXPORT (ProRes MOV, HEVC MP4, MKV, WebM) is converted to H.264 MP4 for Social Media
            if [ "${PROBE_HAS_VIDEO:-0}" -gt 0 ] && [ "${PROBE_IS_ATTACHED_PIC:-0}" -eq 0 ]; then
                max_dim=${PROBE_WIDTH:-0}
                [ "${PROBE_HEIGHT:-0}" -gt "$max_dim" ] && max_dim=$PROBE_HEIGHT

                target_bitrate="12M"
                label="Full HD (1080p)"

                if [ "$max_dim" -ge 3800 ]; then
                    label="4K (2160p)"
                    if [ "$PROBE_FPS" -gt 32 ]; then target_bitrate="35M"; else target_bitrate="28M"; fi
                elif [ "$max_dim" -ge 2400 ]; then
                    label="2K (1440p)"
                    if [ "$PROBE_FPS" -gt 32 ]; then target_bitrate="22M"; else target_bitrate="18M"; fi
                elif [ "$max_dim" -ge 1800 ]; then
                    label="Full HD (1080p)"
                    if [ "$PROBE_FPS" -gt 32 ]; then target_bitrate="15M"; else target_bitrate="12M"; fi
                else
                    label="HD (720p)"
                    if [ "$PROBE_FPS" -gt 32 ]; then target_bitrate="10M"; else target_bitrate="8M"; fi
                fi

                echo ""
                echo -e "${C_MAGENTA}${C_BOLD}┌─ [ 📤 EXPORT -> Social Media MP4 ] ──────────────────────────────────────┐${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_BOLD}File:${C_RESET}        $filename"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Format:${C_RESET}      ${PROBE_WIDTH}x${PROBE_HEIGHT} ($label @ ${PROBE_FPS}FPS | Audio Tracks: $PROBE_HAS_AUDIO)"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}H.264 MP4 (yuv420p | Bitrate: $target_bitrate)${C_RESET}"
                if [ "$ENCODER_MODE" == "CPU" ]; then
                    echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Encoder:${C_RESET}     ${C_YELLOW}${C_BOLD}CPU (libx264 - $CPU_PRESET)${C_RESET}"
                else
                    echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Encoder:${C_RESET}     ${C_GREEN}${C_BOLD}Hardware ($ENCODER_MODE GPU Acceleration)${C_RESET}"
                fi
                echo -e "${C_MAGENTA}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mp4="$FINAL_DIR/${base_name}_social.mp4"
                out_mp4=$(get_unique_path "$out_mp4")

                local ret=1

                if [ "$ENCODER_MODE" == "NVENC" ]; then
                    run_ffmpeg_with_progress "$file" "NVIDIA Export: $filename" "$out_mp4" \
                        -y -i "$file" \
                        -map "0:v?" -map "0:a?" -map_chapters 0 \
                        -c:v h264_nvenc -b:v "$target_bitrate" -pix_fmt yuv420p \
                        -c:a aac -b:a "$AUDIO_BITRATE" "$out_mp4"
                    ret=$?

                elif [ "$ENCODER_MODE" == "QSV" ]; then
                    run_ffmpeg_with_progress "$file" "Intel QSV Export: $filename" "$out_mp4" \
                        -y -i "$file" \
                        -map "0:v?" -map "0:a?" -map_chapters 0 \
                        -c:v h264_qsv -b:v "$target_bitrate" -pix_fmt yuv420p \
                        -c:a aac -b:a "$AUDIO_BITRATE" "$out_mp4"
                    ret=$?

                elif [ "$ENCODER_MODE" == "VAAPI" ]; then
                    run_ffmpeg_with_progress "$file" "AMD VAAPI Export: $filename" "$out_mp4" \
                        -vaapi_device /dev/dri/renderD128 \
                        -y -i "$file" \
                        -map "0:v?" -map "0:a?" -map_chapters 0 \
                        -vf 'format=nv12,hwupload' \
                        -c:v h264_vaapi -b:v "$target_bitrate" \
                        -c:a aac -b:a "$AUDIO_BITRATE" "$out_mp4"
                    ret=$?
                fi

                if [ $ret -ne 0 ]; then
                    [ "$ENCODER_MODE" != "CPU" ] && echo -e "  ${C_YELLOW}${C_BOLD}[INFO / FALLBACK]${C_RESET} Switching to CPU encoder (libx264 -threads 0)..."
                    
                    run_ffmpeg_with_progress "$file" "CPU Export: $filename" "$out_mp4" \
                        -threads 0 \
                        -y -i "$file" \
                        -map "0:v?" -map "0:a?" -map_chapters 0 \
                        -c:v libx264 -preset "$CPU_PRESET" -b:v "$target_bitrate" -maxrate "$target_bitrate" -bufsize "28M" -pix_fmt yuv420p \
                        -c:a aac -b:a "$AUDIO_BITRATE" "$out_mp4"
                    ret=$?
                fi

                if [ $ret -eq 0 ] && [ -s "$out_mp4" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 3_FINAL_SOCIAL/$(basename -- "$out_mp4")"
                    ((pass_processed++))
                    ((total_processed++))
                    ((export_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of video '$filename' failed."
                    failed_files["$file"]=1
                fi

            else
                echo ""
                echo -e "${C_MAGENTA}${C_BOLD}┌─ [ 🎵 EXPORT Audio -> Social Media MP3 ] ─────────────────────────────────┐${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_BOLD}File:${C_RESET}        $filename"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}MP3 Audio ($AUDIO_BITRATE Bitrate)${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Encoder:${C_RESET}     ${C_YELLOW}${C_BOLD}CPU (libmp3lame)${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mp3="$FINAL_DIR/${base_name}_social.mp3"
                out_mp3=$(get_unique_path "$out_mp3")

                run_ffmpeg_with_progress "$file" "Export MP3: $filename" "$out_mp3" \
                    -vn -y -i "$file" \
                    -c:a libmp3lame -b:a "$AUDIO_BITRATE" "$out_mp3"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_mp3" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 3_FINAL_SOCIAL/$(basename -- "$out_mp3")"
                    ((pass_processed++))
                    ((total_processed++))
                    ((export_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of audio '$filename' failed."
                    failed_files["$file"]=1
                fi
            fi
        done

        [ $pass_processed -eq 0 ] && break
    done

    if [ $total_processed -gt 0 ]; then
        echo ""
        echo -e "${C_GREEN}${C_BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_BOLD}🎉 PROCESSING COMPLETED SUCCESSFULLY!${C_RESET}                                          ${C_GREEN}${C_BOLD}║${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}╠════════════════════════════════════════════════════════════════════════════════╣${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_DIM}Total Converted    :${C_RESET} ${C_BOLD}$total_processed files${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_DIM}DaVinci Prep Files :${C_RESET} ${C_BOLD}$import_processed (ProRes / WAV PCM)${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_DIM}Social Media Exports:${C_RESET} ${C_BOLD}$export_processed (H.264 / MP3)${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${C_RESET}"

        send_notification "DavinciConvert" "🎉 Processing completed! Converted $total_processed files."
    fi
}

if [ $WATCH_MODE -eq 1 ]; then
    echo ""
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    echo -e " ${C_BOLD}👀 WATCH MODE ACTIVE (Monitoring directory for new files...)${C_RESET}"
    echo -e " ${C_DIM}Press Ctrl+C in this terminal window to stop${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    while true; do
        process_files
        sleep 3
    done
else
    process_files
    echo ""
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    echo -e " ${C_BOLD}✨ All tasks completed.${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"

    # Pause before exiting if opened interactively in terminal TTY
    if [ -t 0 ] && [ -z "$DAVINCICONVERT_HEADLESS" ]; then
        echo ""
        read -p "Press Enter to exit..." || true
    fi
fi
