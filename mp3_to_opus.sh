#!/bin/bash

# Function to show usage
show_usage() {
    echo "Usage: mp3_to_opus [DIRECTORY] [OPTIONS]"
    echo ""
    echo "Convert MP3 files in the specified directory to Opus format."
    echo ""
    echo "Arguments:"
    echo "  DIRECTORY    Directory containing MP3 files (default: current directory)"
    echo ""
    echo "Options:"
    echo "  -b, --bitrate BITRATE    Set bitrate in kbps (default: 32)"
    echo "  -j, --jobs JOBS          Number of parallel jobs (default: number of CPU cores)"
    echo "  -h, --help               Show this help message"
}

# Default values
DIRECTORY="."
BITRATE=32
# Detect number of CPU cores
if command -v nproc &> /dev/null; then
    JOBS=$(nproc)
elif command -v sysctl &> /dev/null && sysctl -n hw.ncpu &> /dev/null; then
    JOBS=$(sysctl -n hw.ncpu)
else
    JOBS=4  # Default if detection fails
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -b|--bitrate)
            BITRATE="$2"
            shift 2
            ;;
        -j|--jobs)
            JOBS="$2"
            shift 2
            ;;
        *)
            if [[ -d "$1" ]]; then
                DIRECTORY="$1"
                shift
            else
                echo "Error: Unknown option or invalid directory: $1"
                show_usage
                exit 1
            fi
            ;;
    esac
done

# Check if directory exists
if [[ ! -d "$DIRECTORY" ]]; then
    echo "Error: Directory '$DIRECTORY' not found."
    exit 1
fi

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is not installed. Please install it first."
    exit 1
fi

# Change to the target directory
cd "$DIRECTORY" || exit 1

# Find all MP3 files (directly in the specified directory)
MP3_FILES=()
for file in *.mp3; do
    # Skip if the loop matched the literal "*.mp3" because no files were found
    [[ -f "$file" ]] || continue
    MP3_FILES+=("$file")
done

if [ ${#MP3_FILES[@]} -eq 0 ]; then
    echo "No MP3 files found in '$DIRECTORY'."
    exit 0
fi

echo "Found ${#MP3_FILES[@]} MP3 files. Converting with $JOBS parallel jobs..."

# Simple bash implementation with job control
convert_file() {
    local file="$1"
    local bitrate="$2"
    local filename="${file%.*}"
    echo "Converting: $file"
    ffmpeg -i "$file" -c:a libopus -b:a "${bitrate}k" "${filename}.opus" -y -loglevel error
}

# Process files with limited concurrency
running=0
for file in "${MP3_FILES[@]}"; do
    # Wait for a slot if we're at max jobs
    if [[ $running -ge $JOBS ]]; then
        wait -n  # Wait for any child to finish
        ((running--))
    fi
    
    # Start a new conversion
    convert_file "$file" "$BITRATE" &
    ((running++))
done

# Wait for remaining jobs
wait

echo "Conversion complete."

