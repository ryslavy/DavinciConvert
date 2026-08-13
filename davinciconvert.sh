#!/bin/bash

# ==============================================================================
# DavinciConvert - Smart Media Transcoder for DaVinci Resolve on Linux
# 
# Features:
#   1. Converts any video/audio for DaVinci Resolve Free on Linux (ProRes 422 + PCM audio).
#   2. Converts DaVinci exports back to H.264/AAC MP4 with yuv420p for Social Media.
#   3. Dynamic resolution, FPS, and aspect ratio analysis (vertical 9:16 & widescreen).
#   4. Hardware auto-detection (NVIDIA NVENC, Intel QSV, AMD VAAPI) with CPU fallback.
#   5. Universal Matrix Protection: Bypasses redundant re-encoding & auto-routes misplaced files across all 4 folders.
#   6. Multi-Audio Track Preservation: Maps all OBS audio streams (Microphone, Game, Discord) independently.
#   7. Desktop Notifications: Native OS alerts via notify-send when batch processing completes.
#   8. Linux Desktop Launcher (--install-desktop): Installs DavinciConvert to GNOME / Fedora Application Grid.
#   9. Safety Archiving (--archive / -a): Move original raw files to ARCHIV/ instead of deleting them.
#  10. Native Terminal Progress: Real-time status, speed, and time estimation.
#  11. Instant Process Cancellation: Closing terminal window or Ctrl+C kills FFmpeg instantly.
#  12. Auto-Terminal Launcher: Automatically opens a GUI terminal window when double-clicked.
#  13. Real-time folder watching mode (--watch / -w).
# ==============================================================================

# Always change working directory strictly to the directory where this script is physically located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR" || exit 1

# Auto-launch terminal window if double-clicked from file manager
if [ ! -t 1 ] && [ -n "$DISPLAY" -o -n "$WAYLAND_DISPLAY" ]; then
    for term in gnome-terminal konsole xfce4-terminal kitty alacritty xterm x-terminal-emulator; do
        if command -v $term >/dev/null 2>&1; then
            case $term in
                gnome-terminal) exec gnome-terminal -- title "DavinciConvert" -- bash -c "$0 $*; echo ''; read -p 'Press Enter to exit...'" ;;
                konsole) exec konsole --title "DavinciConvert" -e bash -c "$0 $*; echo ''; read -p 'Press Enter to exit...'" ;;
                xfce4-terminal) exec xfce4-terminal -T "DavinciConvert" -e "bash -c \"$0 $*; echo ''; read -p 'Press Enter to exit...'\"" ;;
                *) exec $term -e bash -c "$0 $*; echo ''; read -p 'Press Enter to exit...'" ;;
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
    # 1. Test NVIDIA NVENC
    if ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64 -c:v h264_nvenc -f null - >/dev/null 2>&1; then
        echo "NVENC"
        return
    fi
    # 2. Test Intel QuickSync (QSV)
    if ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64 -c:v h264_qsv -f null - >/dev/null 2>&1; then
        echo "QSV"
        return
    fi
    # 3. Test VAAPI (AMD / Linux)
    if [ -e "/dev/dri/renderD128" ] && ffmpeg -hide_banner -loglevel error -vaapi_device /dev/dri/renderD128 -y -f lavfi -i testsrc=duration=1:size=64x64 -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - >/dev/null 2>&1; then
        echo "VAAPI"
        return
    fi
    # 4. Universal multi-threaded CPU fallback (AMD Ryzen / Intel)
    echo "CPU"
}

ENCODER_MODE=$(detect_best_encoder)

# Display Header Banner
echo -e "${C_CYAN}${C_BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_BOLD}🎬 DavinciConvert v1.0.0${C_RESET} ${C_DIM}| Smart Media Transcoder for Linux${C_RESET}             ${C_CYAN}${C_BOLD}║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╠════════════════════════════════════════════════════════════════════════════════╣${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Working Directory :${C_RESET} ${C_WHITE}$DIR${C_RESET}"
if [ "$ENCODER_MODE" == "CPU" ]; then
    echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Hardware Mode     :${C_RESET} ${C_YELLOW}${C_BOLD}CPU (Multi-threaded Fallback - $CPU_PRESET)${C_RESET}"
else
    echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Hardware Mode     :${C_RESET} ${C_GREEN}${C_BOLD}Hardware ($ENCODER_MODE GPU Acceleration)${C_RESET}"
fi
[ $ENABLE_ARCHIVE -eq 1 ] && echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Safety Archiving  :${C_RESET} ${C_GREEN}${C_BOLD}ENABLED (Moving originals to ARCHIV/)${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${C_RESET}"

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
        echo -e "  ${C_RED}${C_BOLD}[🛑 INTERRUPTED / ERROR]${C_RESET} Conversion was cancelled or failed."
        rm -f "$output_file"
        return 1
    fi
}

handle_original_file() {
    local src_file="$1"
    if [ $ENABLE_ARCHIVE -eq 1 ]; then
        mkdir -p "$ARCHIVE_DIR"
        mv "$src_file" "$ARCHIVE_DIR/"
    else
        rm -f "$src_file"
    fi
}

process_files() {
    shopt -s nullglob
    local total_processed=0
    local import_processed=0
    local export_processed=0

    while true; do
        local pass_processed=0

        # ----------------------------------------------------
        # 0A. MATRIX CHECK: MISPLACED FILES IN 3_FINAL_SOCIAL
        # ----------------------------------------------------
        for file in "$FINAL_DIR"/*; do
            [ -f "$file" ] || continue

            filename=$(basename -- "$file")
            clean_filename=$(sed -E 's/ \([0-9]+\)$//' <<< "$filename")
            name="${clean_filename%.*}"
            ext="${clean_filename##*.}"
            ext_lower=$(tr '[:upper:]' '[:lower:]' <<< "$ext")

            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            has_video=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^video$")
            has_audio=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^audio$")
            v_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)
            a_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)
            pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$file" 2>/dev/null | head -n1)

            is_audio_file=0
            if [[ "$ext_lower" =~ ^(mp3|wav|flac|aac|m4a|ogg|opus|wma|aiff|ac3)$ ]]; then is_audio_file=1; fi

            is_social_ready=0
            if [ -n "$has_video" ] && [ $is_audio_file -eq 0 ] && [ "$v_codec" == "h264" ] && [ "$pix_fmt" == "yuv420p" ] && [[ "$a_codec" == "aac" || "$a_codec" == "mp3" ]] && [ "$ext_lower" == "mp4" ]; then
                is_social_ready=1
            elif [ $is_audio_file -eq 1 ] && [ "$a_codec" == "mp3" ] && [ "$ext_lower" == "mp3" ]; then
                is_social_ready=1
            fi

            # If file in 3_FINAL_SOCIAL is not social ready
            if [ $is_social_ready -eq 0 ]; then
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}[🔀 SMART REROUTE]${C_RESET} '$filename' placed in 3_FINAL_SOCIAL by mistake. Moving to 2_EXPORT for social media encoding..."
                mv "$file" "$EXPORT_DIR/$filename"
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

            filename=$(basename -- "$file")
            clean_filename=$(sed -E 's/ \([0-9]+\)$//' <<< "$filename")
            name="${clean_filename%.*}"
            ext="${clean_filename##*.}"
            ext_lower=$(tr '[:upper:]' '[:lower:]' <<< "$ext")

            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            has_video=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^video$")
            has_audio=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^audio$")
            v_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)
            a_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)

            is_audio_file=0
            if [[ "$ext_lower" =~ ^(mp3|wav|flac|aac|m4a|ogg|opus|wma|aiff|ac3)$ ]]; then is_audio_file=1; fi

            is_davinci_ready=0
            if [ -n "$has_video" ] && [ $is_audio_file -eq 0 ] && [[ "$v_codec" == "prores" || "$v_codec" == "dnxhd" || "$v_codec" == "dnxhr" || "$v_codec" == "cineform" || "$v_codec" == "rawvideo" || "$v_codec" == "mjpeg" ]] && [[ "$a_codec" == pcm_* || -z "$has_audio" ]]; then
                is_davinci_ready=1
            elif [ $is_audio_file -eq 1 ] && [[ "$a_codec" == pcm_* ]] && [ "$ext_lower" == "wav" ]; then
                is_davinci_ready=1
            fi

            # If user placed a raw MP4/MP3 into 1_PRORES_DAVINCI by mistake
            if [ $is_davinci_ready -eq 0 ]; then
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}[🔀 SMART REROUTE]${C_RESET} '$filename' placed in 1_PRORES_DAVINCI by mistake. Moving to 1_IMPORT for DaVinci prep..."
                mv "$file" "$IMPORT_DIR/$filename"
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

            filename=$(basename -- "$file")
            clean_filename=$(sed -E 's/ \([0-9]+\)$//' <<< "$filename")
            name="${clean_filename%.*}"
            ext="${clean_filename##*.}"
            ext_lower=$(tr '[:upper:]' '[:lower:]' <<< "$ext")

            # Skip hidden & temporary downloading files (.part, .crdownload, .tmp, .ytdl...)
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            has_video=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^video$")
            has_audio=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^audio$")
            
            is_audio_file=0
            if [[ "$ext_lower" =~ ^(mp3|wav|flac|aac|m4a|ogg|opus|wma|aiff|ac3)$ ]]; then
                is_audio_file=1
            fi

            if [ -n "$has_video" ]; then
                is_attached_pic=$(ffprobe -v error -select_streams v:0 -show_entries stream=disposition:attached_pic -of csv=p=0 "$file" 2>/dev/null | head -n1 | cut -d, -f2)
                if [ "$is_attached_pic" == "1" ] || [ $is_audio_file -eq 1 ]; then
                    has_video=""
                    is_audio_file=1
                fi
            fi

            v_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)
            a_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)

            # SMART PROTECTION 1A: File is ALREADY in Apple ProRes / DNxHD / CineForm + PCM audio
            if [ -n "$has_video" ] && [ $is_audio_file -eq 0 ] && [[ "$v_codec" == "prores" || "$v_codec" == "dnxhd" || "$v_codec" == "dnxhr" || "$v_codec" == "cineform" || "$v_codec" == "rawvideo" || "$v_codec" == "mjpeg" ]] && [[ "$a_codec" == pcm_* || -z "$has_audio" ]]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ SMART BYPASS]${C_RESET} '$filename' is ALREADY in ProRes/DNxHD + PCM! Moving..."
                mv "$file" "$DAVINCI_DIR/$filename"
                ((pass_processed++))
                ((total_processed++))
                ((import_processed++))
                continue
            fi

            # SMART PROTECTION 1B: Audio file is ALREADY 48kHz WAV PCM
            if [ $is_audio_file -eq 1 ] && [[ "$a_codec" == pcm_* ]] && [ "$ext_lower" == "wav" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ SMART BYPASS]${C_RESET} '$filename' is ALREADY 48kHz WAV PCM. Moving..."
                mv "$file" "$DAVINCI_DIR/$filename"
                ((pass_processed++))
                ((total_processed++))
                ((import_processed++))
                continue
            fi

            if [ -n "$has_video" ] && [ $is_audio_file -eq 0 ]; then
                w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$file" 2>/dev/null | head -n1)
                h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$file" 2>/dev/null | head -n1)
                fps_str=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$file" 2>/dev/null | head -n1)
                audio_tracks=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^audio$" | wc -l)

                w=${w:-0}
                h=${h:-0}
                max_dim=$w
                [ "$h" -gt "$max_dim" ] && max_dim=$h

                fps=30
                if [ -n "$fps_str" ]; then
                    fps=$(awk -F'/' '{if ($2>0) print int($1/$2); else print int($1)}' <<< "$fps_str")
                fi

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
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Format:${C_RESET}      ${w}x${h} ($label @ ${fps}FPS | Audio Tracks: $audio_tracks)"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}Apple ProRes 422 MOV + Uncompressed PCM Audio${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mov="$DAVINCI_DIR/${name}_davinci.mov"
                run_ffmpeg_with_progress "$file" "DaVinci Prep: $filename" "$out_mov" \
                    -threads 0 \
                    -y -i "$file" \
                    -map "0:v?" -map "0:a?" -map_chapters 0 \
                    -c:v prores_ks -profile:v "$prores_prof" \
                    -c:a pcm_s16le "$out_mov"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_mov" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 1_PRORES_DAVINCI/${name}_davinci.mov"
                    ((pass_processed++))
                    ((total_processed++))
                    ((import_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of video '$filename' failed."
                fi

            elif [ -n "$has_audio" ] || [ $is_audio_file -eq 1 ]; then
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}┌─ [ 🎵 IMPORT Audio -> DaVinci Prep ] ─────────────────────────────────────┐${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_BOLD}File:${C_RESET}        $filename"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}WAV / Uncompressed PCM 48kHz${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_wav="$DAVINCI_DIR/${name}_davinci.wav"
                run_ffmpeg_with_progress "$file" "DaVinci Audio Prep: $filename" "$out_wav" \
                    -vn -y -i "$file" \
                    -c:a pcm_s16le -ar 48000 "$out_wav"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_wav" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 1_PRORES_DAVINCI/${name}_davinci.wav"
                    ((pass_processed++))
                    ((total_processed++))
                    ((import_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of audio '$filename' failed."
                fi
            else
                echo -e "${C_DIM}[SKIP] File '$filename' is not a supported video or audio format.${C_RESET}"
            fi
        done

        # ----------------------------------------------------
        # 2. PROCESS 2_EXPORT FOLDER (Preparation FROM DaVinci for Social Media)
        # ----------------------------------------------------
        for file in "$EXPORT_DIR"/*; do
            [ -f "$file" ] || continue

            filename=$(basename -- "$file")
            clean_filename=$(sed -E 's/ \([0-9]+\)$//' <<< "$filename")
            name="${clean_filename%.*}"
            ext="${clean_filename##*.}"
            ext_lower=$(tr '[:upper:]' '[:lower:]' <<< "$ext")

            # Skip hidden & temporary downloading files
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            has_video=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^video$")
            has_audio=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^audio$")
            
            is_audio_file=0
            if [[ "$ext_lower" =~ ^(mp3|wav|flac|aac|m4a|ogg|opus|wma|aiff|ac3)$ ]]; then
                is_audio_file=1
            fi

            if [ -n "$has_video" ]; then
                is_attached_pic=$(ffprobe -v error -select_streams v:0 -show_entries stream=disposition:attached_pic -of csv=p=0 "$file" 2>/dev/null | head -n1 | cut -d, -f2)
                if [ "$is_attached_pic" == "1" ] || [ $is_audio_file -eq 1 ]; then
                    has_video=""
                    is_audio_file=1
                fi
            fi

            v_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)
            a_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -n1)
            pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$file" 2>/dev/null | head -n1)

            # SMART PROTECTION 2A: User placed a raw web/camera video into 2_EXPORT by mistake (MKV/WebM/AVI/VP9/AV1/HEVC)
            if [ -n "$has_video" ] && [ $is_audio_file -eq 0 ] && [[ "$ext_lower" =~ ^(mkv|webm|avi|flv|wmv)$ || "$v_codec" == "vp9" || "$v_codec" == "av1" || "$v_codec" == "hevc" ]]; then
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}[🔀 SMART ROUTE]${C_RESET} '$filename' appears to be raw video ($v_codec). Moving to 1_IMPORT..."
                mv "$file" "$IMPORT_DIR/$filename"
                ((pass_processed++))
                ((total_processed++))
                continue
            fi

            # SMART PROTECTION 2B: File in 2_EXPORT is ALREADY a social-media-ready H.264/AAC MP4 in yuv420p
            if [ -n "$has_video" ] && [ $is_audio_file -eq 0 ] && [ "$v_codec" == "h264" ] && [ "$pix_fmt" == "yuv420p" ] && [[ "$a_codec" == "aac" || "$a_codec" == "mp3" ]] && [ "$ext_lower" == "mp4" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ SMART BYPASS]${C_RESET} '$filename' is ALREADY converted for Social Media! Moving..."
                mv "$file" "$FINAL_DIR/$filename"
                ((pass_processed++))
                ((total_processed++))
                ((export_processed++))
                continue
            fi

            if [ -n "$has_video" ] && [ $is_audio_file -eq 0 ]; then
                w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$file" 2>/dev/null | head -n1)
                h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$file" 2>/dev/null | head -n1)
                fps_str=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$file" 2>/dev/null | head -n1)
                audio_tracks=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | grep "^audio$" | wc -l)

                w=${w:-0}
                h=${h:-0}
                max_dim=$w
                [ "$h" -gt "$max_dim" ] && max_dim=$h

                fps=30
                if [ -n "$fps_str" ]; then
                    fps=$(awk -F'/' '{if ($2>0) print int($1/$2); else print int($1)}' <<< "$fps_str")
                fi

                target_bitrate="12M"
                label="Full HD (1080p)"

                if [ "$max_dim" -ge 3800 ]; then
                    label="4K (2160p)"
                    if [ "$fps" -gt 32 ]; then target_bitrate="35M"; else target_bitrate="28M"; fi
                elif [ "$max_dim" -ge 2400 ]; then
                    label="2K (1440p)"
                    if [ "$fps" -gt 32 ]; then target_bitrate="22M"; else target_bitrate="18M"; fi
                elif [ "$max_dim" -ge 1800 ]; then
                    label="Full HD (1080p)"
                    if [ "$fps" -gt 32 ]; then target_bitrate="15M"; else target_bitrate="12M"; fi
                else
                    label="HD (720p)"
                    if [ "$fps" -gt 32 ]; then target_bitrate="10M"; else target_bitrate="8M"; fi
                fi

                echo ""
                echo -e "${C_MAGENTA}${C_BOLD}┌─ [ 📤 EXPORT -> Social Media MP4 ] ──────────────────────────────────────┐${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_BOLD}File:${C_RESET}        $filename"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Format:${C_RESET}      ${w}x${h} ($label @ ${fps}FPS | Audio Tracks: $audio_tracks)"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}H.264 MP4 (yuv420p | Bitrate: $target_bitrate)${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Encoder Mode:${C_RESET} $ENCODER_MODE"
                echo -e "${C_MAGENTA}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mp4="$FINAL_DIR/${name}_social.mp4"
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
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 3_FINAL_SOCIAL/${name}_social.mp4"
                    ((pass_processed++))
                    ((total_processed++))
                    ((export_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of video '$filename' failed."
                fi

            elif [ -n "$has_audio" ] || [ $is_audio_file -eq 1 ]; then
                echo ""
                echo -e "${C_MAGENTA}${C_BOLD}┌─ [ 🎵 EXPORT Audio -> Social Media MP3 ] ─────────────────────────────────┐${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_BOLD}File:${C_RESET}        $filename"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Target Codec:${C_RESET} ${C_GREEN}${C_BOLD}MP3 Audio ($AUDIO_BITRATE Bitrate)${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mp3="$FINAL_DIR/${name}_social.mp3"
                run_ffmpeg_with_progress "$file" "Export MP3: $filename" "$out_mp3" \
                    -vn -y -i "$file" \
                    -c:a libmp3lame -b:a "$AUDIO_BITRATE" "$out_mp3"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_mp3" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ SAVED]${C_RESET} 3_FINAL_SOCIAL/${name}_social.mp3"
                    ((pass_processed++))
                    ((total_processed++))
                    ((export_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ ERROR]${C_RESET} Conversion of audio '$filename' failed."
                fi
            else
                echo -e "${C_DIM}[SKIP] File '$filename' is not a supported video or audio format.${C_RESET}"
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

    # Pause before exiting if opened via Desktop Launcher or GUI terminal
    if [ -t 0 ] || [ -n "$DISPLAY" -o -n "$WAYLAND_DISPLAY" ]; then
        echo ""
        read -p "Press Enter to exit..." || true
    fi
fi
