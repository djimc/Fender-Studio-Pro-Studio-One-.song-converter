# Fender Studio Pro / Studio-One .song-converter
A Linux bash script for converting Studio Pro 8 and Studio One 7 .song files


PLEASE NOTE THIS WAS WRITTEN WITH AI!!! I am not a developer. I only guided the bot what I need to be created, tested and fine-tuned the script. The previously known process of converting was leaving us with a missing EQ pligin. I only "fixed" that on top of what was already known. I will update the script if/when I find other native plugins are reported missing when downgrading from v8.

This script will convert/downgrade a Fender Studio Pro 8 OR a Studio One v7 .song file to either v7 or v6 .song file. Multiple .song files are supported and processed at once. The script detects what .song files have been dropped and presents you with an interactive menu. The process is non-distructive. It places the converted files next to the original .song files, keeping the originals intact. 

The script makes projects saved in v8 usable with v7 and v6 again. 

I have also "created" a small cross-platform GUI app based on this script which I will upload after I test for other plugins that need "fixing".
Usage: 1. allow executing 2. ./StudioPro2StudioOne.sh /path/to/file(s)/to/be/converted.song

Screenshots:
<img width="1010" height="201" alt="Screenshot_1" src="https://github.com/user-attachments/assets/ce074f8a-e3a9-4e25-93db-c992a8b396b1" />
<img width="1006" height="168" alt="Screenshot_2" src="https://github.com/user-attachments/assets/06d5f969-c253-4286-bda3-0290b9156d7f" />
<img width="1006" height="179" alt="Screenshot_3" src="https://github.com/user-attachments/assets/2f75706c-b6dd-4ed0-9f1b-2e7a9f582a32" />
<img width="1006" height="369" alt="Screenshot_4" src="https://github.com/user-attachments/assets/03863e84-d651-4b82-bab7-0820d934429c" />
