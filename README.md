# DavinciConvert

DavinciConvert is an automated media transcoding utility designed specifically for DaVinci Resolve Free on Linux and social media video publishing.

---

## About the Project

DaVinci Resolve Free on Linux has native codec and container limitations due to proprietary software licensing restrictions:
- No native H.264 or H.265 video decoding within standard media containers on Linux Free edition.
- No native AAC audio decoding, which results in imported clips having missing or silent audio.
- Format incompatibilities when exporting edited footage back to web platforms (such as missing `yuv420p` pixel format support on mobile devices).

DavinciConvert automates the entire preparation and export pipeline:
1. **Import (To DaVinci):** Converts raw video and audio files into Apple ProRes 422 MOV and uncompressed 16-bit 48kHz PCM audio, ensuring smooth scrubbing and full timeline compatibility.
2. **Export (To Social Media):** Converts master renders from DaVinci Resolve back into lightweight H.264 MP4 (`yuv420p`) and AAC audio for Instagram, TikTok, YouTube Shorts, and web distribution.

---

## Key Features

- **State-Machine Routing Engine:** 1-pass `ffprobe` metadata inspection with deterministic state machine routing across all 4 directories.
- **Multi-Audio Track Preservation:** Automatically maps and preserves all independent audio streams from OBS Studio recordings (Microphone, Game Audio, Discord) into separate audio tracks for DaVinci Resolve.
- **Collision-Safe File Movement:** Prevents accidental file overwrites when auto-routing files with identical names.
- **Quarantine System:** Moves corrupt, zero-byte, or unreadable media files into a `POŠKOZENÉ/` (or `CORRUPTED/`) directory automatically.
- **Date-Based Safety Archiving:** Organizes archived raw input files into clean `ARCHIV/YYYY-MM-DD/` directories via `--archive`.
- **Desktop Notifications:** Sends native OS desktop notifications via `notify-send` when batch processing completes.
- **Linux Desktop Launcher:** Generates and installs a native `.desktop` application launcher into GNOME / Fedora application menus via `--install-desktop`.
- **Subtitle & Chapter Preservation:** Preserves embedded subtitle tracks and chapter markers during transcoding.
- **Universal Smart Routing Matrix:** Uses `ffprobe` to inspect media streams directly and reroutes misplaced files across folders automatically.
- **Hardware Acceleration:** Auto-probes NVIDIA NVENC, Intel QSV, and AMD VA-API with zero-crash CPU multi-threading fallback.
- **Instant Cancellation:** Pressing Ctrl+C or closing the terminal window terminates FFmpeg immediately in 0.0001s.

---

## System Architecture and Workflow

DavinciConvert operates using a four-directory workflow.

### Directory Structure

```text
DavinciConvert/
├── 1_IMPORT/          Input directory for raw videos and audio files
├── 1_PRORES_DAVINCI/  Output directory containing converted ProRes MOV and WAV PCM files
├── 2_EXPORT/          Input directory for master renders exported from DaVinci Resolve
├── 3_FINAL_SOCIAL/    Output directory containing optimized H.264 MP4 and MP3 files (HOTOVO in CZ)
├── ARCHIV/            (Optional) Safety archive directory for original input files (ARCHIV/YYYY-MM-DD/)
└── CORRUPTED/         Quarantine directory for broken or unreadable files (POŠKOZENÉ in CZ)
```

### Media Processing Pipeline

```mermaid
graph TD
    A["Raw Input File (MP4, MKV, WebM, HEVC, AV1, MP3, FLAC)"] -->|Drop into 1_IMPORT| B("DavinciConvert Engine")
    B -->|Transcode to ProRes 422 + Multi-Track PCM 48kHz| C["1_PRORES_DAVINCI (ProRes MOV / WAV)"]
    C -->|Import & Edit| D["DaVinci Resolve Free on Linux"]
    D -->|Render Master Export| E["2_EXPORT (ProRes MOV / WAV Master)"]
    E -->|Transcode to H.264 yuv420p + AAC| F("DavinciConvert Engine")
    F -->|Output Optimized File| G["3_FINAL_SOCIAL (H.264 MP4 / MP3)"]
```

---

## Universal Smart Routing Matrix

DavinciConvert uses `ffprobe` to inspect media streams directly rather than relying on file extensions. If a file is placed in an incorrect directory by mistake, the script automatically routes it to the appropriate processing pipeline.

```mermaid
flowchart LR
    File["Media File Dropped"] --> Probe{"Stream Analysis (ffprobe)"}
    Probe -->|ProRes / PCM WAV| DavinciOut["1_PRORES_DAVINCI (Bypass Encoding)"]
    Probe -->|H.264 yuv420p / MP3| SocialOut["3_FINAL_SOCIAL (Bypass Encoding)"]
    Probe -->|Raw Camera Video / Audio| ImportRoute["Route to 1_IMPORT -> Convert to ProRes"]
    Probe -->|Master Render MOV / WAV| ExportRoute["Route to 2_EXPORT -> Convert to H.264 MP4"]
```

---

## CLI Flags & Advanced Options

DavinciConvert supports a set of command-line flags to customize quality, execution modes, archiving, and desktop integration:

```text
Usage: ./davinciconvert.sh [OPTIONS]  (or ./START.sh [OPTIONS])

Options:
  -w, --watch            Watch directory continuously for new files in real time
  -a, --archive          Move original raw files into ARCHIV/YYYY-MM-DD/ instead of deleting
  -q, --quality <lt|std|hq>  Set ProRes quality profile (lt = ProRes LT, std = Standard, hq = ProRes HQ)
  -p, --preset <preset>   Set CPU encoding speed (ultrafast, superfast, fast, medium, slow)
  --install-desktop      Install Linux Desktop Launcher into application grid
  -h, --help             Show help menu
```

### Detailed Flag Descriptions

#### 1. Real-Time Watch Mode (`-w` / `--watch`)
Keeps the script running continuously in the background, polling directories every 3 seconds for new incoming files.
```bash
./davinciconvert.sh --watch
```

#### 2. Date-Based Safety Archiving (`-a` / `--archive`)
Instead of removing raw input files after successful transcoding, moves them to a date-stamped folder inside `ARCHIV/YYYY-MM-DD/`.
```bash
./davinciconvert.sh --archive
```

#### 3. ProRes Quality Overrides (`-q` / `--quality`)
Allows forcing a specific Apple ProRes 422 profile for DaVinci import preparation:
- `lt`: **ProRes 422 LT** (Lightweight, smaller file size, ideal for 1080p).
- `std` or `standard`: **ProRes 422 Standard** (High quality, ideal for 4K).
- `hq`: **ProRes 422 HQ** (Maximum quality master format).
```bash
./davinciconvert.sh --quality std
```

#### 4. CPU Encoding Speed Preset (`-p` / `--preset`)
Controls the CPU encoding speed/compression ratio for x264 exports (`ultrafast`, `superfast`, `fast`, `medium`, `slow`).
```bash
./davinciconvert.sh --preset fast
```

#### 5. Desktop Application Launcher Installation (`--install-desktop`)
Registers DavinciConvert into your desktop environment's application menu (GNOME, KDE, XFCE). Creates `$HOME/.local/share/applications/DavinciConvert.desktop` pointing directly to the local script.
```bash
./davinciconvert.sh --install-desktop
```

---

## Usage Instructions

### Prerequisites

Ensure `bash` and `ffmpeg` (with `ffprobe`) are installed.

```bash
# Fedora / RHEL
sudo dnf install ffmpeg

# Ubuntu / Debian
sudo apt update && sudo apt install ffmpeg

# Arch Linux
sudo pacman -S ffmpeg
```

### Running the Transcoder

#### Single Pass Execution
Double-click `davinciconvert.sh` (or `START.sh`) from your desktop environment, or run it via the command line:

```bash
./davinciconvert.sh
```

An interactive terminal window will automatically launch, displaying real-time encoding stats and progress. To stop execution at any point, close the terminal window or press `Ctrl+C`.

---

## OBS Studio Configuration Guide

To record footage directly in a native DaVinci-compatible format on Linux without pre-transcoding, configure OBS Studio as follows:

1. Open **OBS Studio -> Settings -> Output -> Recording**.
2. Set **Output Type** to `Custom Output (FFmpeg)`.
3. Set **Container Format** to `mov`.
4. Set **Video Encoder** to `dnxhd` (or `prores_ks`).
5. Set **Audio Encoder** to `pcm_s16le` (or `pcm_s24le`).

---

## Bitrate and Quality Specifications

| Resolution | Aspect Ratio Support | DaVinci Import Profile | Social Export Bitrate (<= 32 FPS) | Social Export Bitrate (> 32 FPS) |
| :--- | :--- | :--- | :--- | :--- |
| 4K (2160p) | Widescreen 16:9 / Vertical 9:16 | ProRes 422 Standard | 28 Mbps | 35 Mbps |
| 2K (1440p) | Widescreen 16:9 / Vertical 9:16 | ProRes 422 LT | 18 Mbps | 22 Mbps |
| Full HD (1080p) | Widescreen 16:9 / Vertical 9:16 | ProRes 422 LT | 12 Mbps | 15 Mbps |
| HD (720p) | Widescreen 16:9 / Vertical 9:16 | ProRes 422 LT | 8 Mbps | 10 Mbps |

---

## License

This project is licensed under the [MIT License](LICENSE).
