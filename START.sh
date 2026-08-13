#!/bin/bash

# ==============================================================================
# UNIVERZÁLNÍ CHYTRÝ KONVERTOR S STAVOVÝM AUTOMATEM, JEDNOPRŮCHODOVOU SONDOU,
# BEZPEČNÝM PŘESMĚROVÁNÍM A PODPOROU VÍCE ZVUKOVÝCH STOP Z OBS STUDIO
# ==============================================================================

# Vždy se přepnout přímo do složky, kde se skript fyzicky nachází
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR" || exit 1

# Automatické otevření terminálového okna při dvojkliku z grafického rozhraní
if [ ! -t 1 ] && [ -n "$DISPLAY" -o -n "$WAYLAND_DISPLAY" ]; then
    for term in gnome-terminal konsole xfce4-terminal kitty alacritty xterm x-terminal-emulator; do
        if command -v $term >/dev/null 2>&1; then
            case $term in
                gnome-terminal) exec gnome-terminal -- title "DavinciConvert" -- bash -c "$0 $*; echo ''; read -p 'Stiskněte Enter pro ukončení...'" ;;
                konsole) exec konsole --title "DavinciConvert" -e bash -c "$0 $*; echo ''; read -p 'Stiskněte Enter pro ukončení...'" ;;
                xfce4-terminal) exec xfce4-terminal -T "DavinciConvert" -e "bash -c \"$0 $*; echo ''; read -p 'Stiskněte Enter pro ukončení...'\"" ;;
                *) exec $term -e bash -c "$0 $*; echo ''; read -p 'Stiskněte Enter pro ukončení...'" ;;
            esac
            exit 0
        fi
    done
fi

# Definice ANSI barev pro reprezentativní konzolové rozhraní
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
FINAL_DIR="$DIR/HOTOVO"
ARCHIVE_DIR="$DIR/ARCHIV"
CORRUPT_DIR="$DIR/POŠKOZENÉ"

# Výchozí konfigurace kvality a zpracování
PRORES_PROFILE_OVERRIDE=""
CPU_PRESET="superfast"
AUDIO_BITRATE="320k"
ENABLE_ARCHIVE=0
WATCH_MODE=0

# Zpracování volitelných CLI argumentů
show_help() {
    echo -e "${C_CYAN}${C_BOLD}DavinciConvert v1.0.0 - Použití:${C_RESET}"
    echo -e "  ./START.sh [MOŽNOSTI]"
    echo ""
    echo -e "${C_BOLD}Možnosti:${C_RESET}"
    echo -e "  -w, --watch            Sledovací režim v reálném čase na pozadí"
    echo -e "  -a, --archive          Přesouvat původní soubory do složky ARCHIV místo mazání"
    echo -e "  -q, --quality <lt|std|hq>  Nastavit kvalitu ProResu (lt = ProRes LT, std = Standard, hq = ProRes HQ)"
    echo -e "  -p, --preset <preset>   Nastavit rychlost CPU komprese (ultrafast, superfast, fast, medium, slow)"
    echo -e "  --install-desktop      Nainstalovat zástupce aplikace do hlavní nabídky Linuxu"
    echo -e "  -h, --help             Zobrazit tuto nápovědu"
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
Exec=bash -c '"$DIR/START.sh"; echo ""; read -p "Stiskněte Enter pro ukončení..."'
Icon=video-x-generic
Terminal=true
Categories=AudioVideo;Video;AudioVideoEditing;
Keywords=davinci;convert;ffmpeg;prores;transcode;
EOF

    chmod +x "$desktop_file"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps_dir" >/dev/null 2>&1
    fi
    echo -e "${C_GREEN}${C_BOLD}[✅ HOTOVO]${C_RESET} Zástupce aplikace spuštěn a nainstalován do: $desktop_file"
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

# Vytvoření složek, pokud ještě neexistují
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
    if ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64 -c:v h264_nvenc -f null - >/dev/null 2>&1; then
        echo "NVENC"
        return
    fi
    if ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=1:size=64x64 -c:v h264_qsv -f null - >/dev/null 2>&1; then
        echo "QSV"
        return
    fi
    if [ -e "/dev/dri/renderD128" ] && ffmpeg -hide_banner -loglevel error -vaapi_device /dev/dri/renderD128 -y -f lavfi -i testsrc=duration=1:size=64x64 -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - >/dev/null 2>&1; then
        echo "VAAPI"
        return
    fi
    echo "CPU"
}

ENCODER_MODE=$(detect_best_encoder)

# Výchozí záhlaví aplikace
echo -e "${C_CYAN}${C_BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_BOLD}🎬 DavinciConvert v1.0.0${C_RESET} ${C_DIM}| Chytrá konverze médií pro Linux${C_RESET}              ${C_CYAN}${C_BOLD}║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╠════════════════════════════════════════════════════════════════════════════════╣${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Pracovní složka  :${C_RESET} ${C_WHITE}$DIR${C_RESET}"
if [ "$ENCODER_MODE" == "CPU" ]; then
    echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Režim akcelerace :${C_RESET} ${C_YELLOW}${C_BOLD}CPU (AMD / Intel Multi-Threading - $CPU_PRESET)${C_RESET}"
else
    echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Režim akcelerace :${C_RESET} ${C_GREEN}${C_BOLD}Hardware ($ENCODER_MODE GPU Acceleration)${C_RESET}"
fi
[ $ENABLE_ARCHIVE -eq 1 ] && echo -e "${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Archivace originálů:${C_RESET} ${C_GREEN}${C_BOLD}ZAPNUTA (Přesouvám do ARCHIV/)${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${C_RESET}"

# Jednoprůchodový extraktor metadat pomocí ffprobe directly into parent shell
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

# Centrální klasifikátor stavu souboru (State Machine Classifier directly setting PROBE_STATE in parent shell)
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

    # 1. Test STAV_DAVINCI_READY
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

    # 2. Test STAV_SOCIAL_READY
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

    # 3. Test STAV_RAW_IMPORT (Jakékoliv surové video/audio vyžadující převod)
    if [ $is_video_file -eq 1 ] || [ "${PROBE_HAS_AUDIO:-0}" -gt 0 ] || [ $is_audio_ext -eq 1 ]; then
        PROBE_STATE="STATE_RAW_IMPORT"
        return 0
    fi

    PROBE_STATE="STATE_INVALID"
    return 1
}

# Bezpečný přesun bez rizika přepsání souboru se stejným názvem
safe_move() {
    local src="$1"
    local dst_dir="$2"
    
    mkdir -p "$dst_dir"
    local fn
    fn=$(basename -- "$src")
    
    local target="$dst_dir/$fn"
    if [ -f "$target" ] && [ "$src" != "$target" ]; then
        local name="${fn%.*}"
        local ext="${fn##*.}"
        local counter=1
        while [ -f "$dst_dir/${name}_${counter}.${ext}" ]; do
            ((counter++))
        done
        target="$dst_dir/${name}_${counter}.${ext}"
    fi

    [ "$src" != "$target" ] && mv "$src" "$target"
}

run_ffmpeg_with_progress() {
    local input="$1"
    local title="$2"
    local output_file="$3"
    shift 3

    rm -f "$output_file"

    # Spuštění FFmpeg s přímým indikátorem stavu a přehledným výstupem
    ffmpeg -hide_banner -loglevel error -stats "$@"
    local res=$?

    if [ $res -eq 0 ] && [ -s "$output_file" ]; then
        return 0
    else
        echo -e "  ${C_RED}${C_BOLD}[🛑 PRERUŠENO / CHYBA]${C_RESET} Konverze byla přerušena nebo selhala."
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
        # 0A. MATICOVÁ KONTROLA NEDAŘENĚ VLOŽENÝCH SOUBORŮ V HOTOVO
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
                echo -e "${C_YELLOW}${C_BOLD}[🔀 CHYTRÉ PŘESMĚROVÁNÍ]${C_RESET} Soubor '$filename' byl vložen do HOTOVO omylem. Přesouvám do 2_EXPORT a konvertuji na sociální sítě..."
                safe_move "$file" "$EXPORT_DIR"
                ((pass_processed++))
                ((total_processed++))
                continue
            fi
        done

        # ----------------------------------------------------
        # 0B. MATICOVÁ KONTROLA NEZKONVERTOVANÝCH SOUBORŮ V 1_PRORES_DAVINCI
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
                echo -e "${C_CYAN}${C_BOLD}[⏩ CHYTRÝ BYPASS]${C_RESET} Soubor '$filename' již JE připraven pro sociální sítě. Přesouvám do HOTOVO..."
                safe_move "$file" "$FINAL_DIR"
                ((pass_processed++))
                ((total_processed++))
                continue
            elif [ "$PROBE_STATE" != "STATE_DAVINCI_READY" ]; then
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}[🔀 CHYTRÉ PŘESMĚROVÁNÍ]${C_RESET} Soubor '$filename' byl vložen do 1_PRORES_DAVINCI omylem. Přesouvám do 1_IMPORT..."
                safe_move "$file" "$IMPORT_DIR"
                ((pass_processed++))
                ((total_processed++))
                continue
            fi
        done

        # ----------------------------------------------------
        # 1. ZPRACOVÁNÍ SLOŽKY 1_IMPORT (Příprava DO DaVinci)
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

            # Ignorovat skryté a dočasně stahované soubory
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            classify_file "$file"

            if [ "$PROBE_STATE" == "STATE_DAVINCI_READY" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ CHYTRÝ BYPASS]${C_RESET} '$filename' již JE v ProRes/DNxHD nebo WAV PCM pro DaVinci. Přesouvám..."
                safe_move "$file" "$DAVINCI_DIR"
                ((pass_processed++))
                ((total_processed++))
                ((import_processed++))
                continue
            elif [ "$PROBE_STATE" == "STATE_SOCIAL_READY" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ CHYTRÝ BYPASS]${C_RESET} '$filename' již JE v H.264/MP3 pro sociální sítě. Přesouvám do HOTOVO..."
                safe_move "$file" "$FINAL_DIR"
                ((pass_processed++))
                ((total_processed++))
                continue
            elif [ "$PROBE_STATE" == "STATE_INVALID" ]; then
                echo ""
                echo -e "${C_RED}${C_BOLD}[🛑 POŠKOZENÝ SOUBOR]${C_RESET} Soubor '$filename' je poškozený nebo nečitelný. Přesouvám do POŠKOZENÉ/..."
                safe_move "$file" "$CORRUPT_DIR"
                ((pass_processed++))
                continue
            fi

            # Stav = STATE_RAW_IMPORT (Zpracujeme převod pro DaVinci)
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
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_BOLD}Soubor:${C_RESET}      $filename"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Formát:${C_RESET}      ${PROBE_WIDTH}x${PROBE_HEIGHT} ($label @ ${PROBE_FPS}FPS | Audio stop: $PROBE_HAS_AUDIO)"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Cílový kodek:${C_RESET} ${C_GREEN}${C_BOLD}Apple ProRes 422 MOV + Uncompressed PCM Audio${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"
                
                local out_mov="$DAVINCI_DIR/${base_name}_davinci.mov"
                run_ffmpeg_with_progress "$file" "Příprava pro DaVinci: $filename" "$out_mov" \
                    -threads 0 \
                    -y -i "$file" \
                    -map "0:v?" -map "0:a?" -map_chapters 0 \
                    -c:v prores_ks -profile:v "$prores_prof" \
                    -c:a pcm_s16le "$out_mov"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_mov" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ ULOŽENO]${C_RESET} 1_PRORES_DAVINCI/${base_name}_davinci.mov"
                    ((pass_processed++))
                    ((total_processed++))
                    ((import_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ CHYBA]${C_RESET} Konverze videa '$filename' nebyla dokončena."
                    failed_files["$file"]=1
                fi

            else
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}┌─ [ 🎵 IMPORT Audio -> DaVinci Prep ] ─────────────────────────────────────┐${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_BOLD}Soubor:${C_RESET}      $filename"
                echo -e "${C_YELLOW}${C_BOLD}│${C_RESET} ${C_DIM}Cílový kodek:${C_RESET} ${C_GREEN}${C_BOLD}WAV / Uncompressed PCM 48kHz${C_RESET}"
                echo -e "${C_YELLOW}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_wav="$DAVINCI_DIR/${base_name}_davinci.wav"
                run_ffmpeg_with_progress "$file" "Příprava audia pro DaVinci: $filename" "$out_wav" \
                    -vn -y -i "$file" \
                    -c:a pcm_s16le -ar 48000 "$out_wav"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_wav" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ ULOŽENO]${C_RESET} 1_PRORES_DAVINCI/${base_name}_davinci.wav"
                    ((pass_processed++))
                    ((total_processed++))
                    ((import_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ CHYBA]${C_RESET} Konverze audia '$filename' nebyla dokončena."
                    failed_files["$file"]=1
                fi
            fi
        done

        # ----------------------------------------------------
        # 2. ZPRACOVÁNÍ SLOŽKY 2_EXPORT (Příprava Z DaVinci na sociální sítě)
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

            # Ignorovat skryté a dočasně stahované soubory
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == *.part || "$filename" == *.crdownload || "$filename" == *.tmp || "$filename" == *.download || "$filename" == *.ytdl ]] && continue

            classify_file "$file"

            if [ "$PROBE_STATE" == "STATE_SOCIAL_READY" ]; then
                echo ""
                echo -e "${C_CYAN}${C_BOLD}[⏩ CHYTRÝ BYPASS]${C_RESET} '$filename' již JE připraveno pro sociální sítě. Přesouvám do HOTOVO..."
                safe_move "$file" "$FINAL_DIR"
                ((pass_processed++))
                ((total_processed++))
                ((export_processed++))
                continue
            elif [ "$PROBE_STATE" == "STATE_INVALID" ]; then
                echo ""
                echo -e "${C_RED}${C_BOLD}[🛑 POŠKOZENÝ SOUBOR]${C_RESET} Soubor '$filename' je poškozený nebo nečitelný. Přesouvám do POŠKOZENÉ/..."
                safe_move "$file" "$CORRUPT_DIR"
                ((pass_processed++))
                continue
            fi

            # Jakýkoliv soubor ve složce 2_EXPORT (ProRes MOV, HEVC MP4, MKV, WebM) převádíme na H.264 MP4 pro sociální sítě
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
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_BOLD}Soubor:${C_RESET}      $filename"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Formát:${C_RESET}      ${PROBE_WIDTH}x${PROBE_HEIGHT} ($label @ ${PROBE_FPS}FPS | Audio stop: $PROBE_HAS_AUDIO)"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Cílový kodek:${C_RESET} ${C_GREEN}${C_BOLD}H.264 MP4 (yuv420p | Bitrate: $target_bitrate)${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Enkodér:${C_RESET}      $ENCODER_MODE"
                echo -e "${C_MAGENTA}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mp4="$FINAL_DIR/${base_name}_social.mp4"
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

                # Pokud HW akcelerace selhala nebo je režim CPU
                if [ $ret -ne 0 ]; then
                    [ "$ENCODER_MODE" != "CPU" ] && echo -e "  ${C_YELLOW}${C_BOLD}[INFO / FALLBACK]${C_RESET} Přepínám na CPU enkodér (AMD/Intel -threads 0)..."
                    
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
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ ULOŽENO]${C_RESET} HOTOVO/${base_name}_social.mp4"
                    ((pass_processed++))
                    ((total_processed++))
                    ((export_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ CHYBA]${C_RESET} Konverze videa '$filename' nebyla dokončena."
                    failed_files["$file"]=1
                fi

            else
                echo ""
                echo -e "${C_MAGENTA}${C_BOLD}┌─ [ 🎵 EXPORT Audio -> Social Media MP3 ] ─────────────────────────────────┐${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_BOLD}Soubor:${C_RESET}      $filename"
                echo -e "${C_MAGENTA}${C_BOLD}│${C_RESET} ${C_DIM}Cílový kodek:${C_RESET} ${C_GREEN}${C_BOLD}MP3 Audio ($AUDIO_BITRATE Bitrate)${C_RESET}"
                echo -e "${C_MAGENTA}${C_BOLD}└──────────────────────────────────────────────────────────────────────────┘${C_RESET}"

                local out_mp3="$FINAL_DIR/${base_name}_social.mp3"
                run_ffmpeg_with_progress "$file" "Export MP3: $filename" "$out_mp3" \
                    -vn -y -i "$file" \
                    -c:a libmp3lame -b:a "$AUDIO_BITRATE" "$out_mp3"

                local ret=$?
                if [ $ret -eq 0 ] && [ -s "$out_mp3" ]; then
                    handle_original_file "$file"
                    echo -e "  ${C_GREEN}${C_BOLD}[✅ ULOŽENO]${C_RESET} HOTOVO/${base_name}_social.mp3"
                    ((pass_processed++))
                    ((total_processed++))
                    ((export_processed++))
                else
                    echo -e "  ${C_RED}${C_BOLD}[❌ CHYBA]${C_RESET} Konverze audia '$filename' nebyla dokončena."
                    failed_files["$file"]=1
                fi
            fi
        done

        [ $pass_processed -eq 0 ] && break
    done

    if [ $total_processed -gt 0 ]; then
        echo ""
        echo -e "${C_GREEN}${C_BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_BOLD}🎉 ZPRACOVÁNÍ USPEŠNĚ DOKONČENO!${C_RESET}                                              ${C_GREEN}${C_BOLD}║${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}╠════════════════════════════════════════════════════════════════════════════════╣${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_DIM}Celkem zkonvertováno :${C_RESET} ${C_BOLD}$total_processed souborů${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_DIM}Příprava pro DaVinci :${C_RESET} ${C_BOLD}$import_processed (ProRes / WAV PCM)${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}║${C_RESET}  ${C_DIM}Export na sítě       :${C_RESET} ${C_BOLD}$export_processed (H.264 / MP3)${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${C_RESET}"

        send_notification "DavinciConvert" "🎉 Zpracování dokončeno! Zkonvertováno $total_processed souborů."
    fi
}

if [ $WATCH_MODE -eq 1 ]; then
    echo ""
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    echo -e " ${C_BOLD}👀 SLEDOVACÍ REŽIM AKTIVNÍ (Čekám na nové soubory...)${C_RESET}"
    echo -e " ${C_DIM}Ukončíte stisknutím Ctrl+C v tomto okně${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    while true; do
        process_files
        sleep 3
    done
else
    process_files
    echo ""
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    echo -e " ${C_BOLD}✨ Všechny úkoly dokončeny.${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"

    # Zamezení okamžitého zavření okna při spuštění ze zástupce nebo GUI
    if [ -t 0 ] || [ -n "$DISPLAY" -o -n "$WAYLAND_DISPLAY" ]; then
        echo ""
        read -p "Stiskněte Enter pro ukončení..." || true
    fi
fi
