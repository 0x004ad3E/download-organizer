# download-organizer
organize downloaded content into folders based on category of download

Refer [qbittorrent-gluetun-protonvpn](https://github.com/0x004ad3E/qbittorrent-gluetun-protonvpn)
After we download the content, on_download_completed.sh is executed. This creates a json file with information of the downloaded content.

In this repository we parse the json file and move the content from the downloads folder of qbittorrent into another folder depending on category.(We support 2 categories as of now : movies and series)

Update .env

Note:
1. The container executes the code and exits. Therefore add to crontab to run it on schedule as required.
2. There is 6 hour wait from the downloaded time until organizing into movies, series folder. This is to ensure seeding. After 6 hours, the torrent is then removed from qbittorrent and the content organized

To start

docker compose up --build

crontab example to run at 14:00 daily. create output folder to hold the logs
0 14 * * * cd /home/admin/download-organizer && { echo "=== Cron started: $(date) ==="; /usr/bin/docker compose up; echo "=== Cron finished: $(date), exit=$? ==="; } > /home/admin/download-organizer/output/cron.log 2>&1


