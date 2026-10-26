# download-organizer
organize downloaded content into folders based on category of download

Refer [qbittorrent-gluetun-protonvpn](https://github.com/0x004ad3E/qbittorrent-gluetun-protonvpn)
After we download the content, on_download_completed.sh is executed. This creates a json file with information of the downloaded content.

In this repository we parse the json file and move the content from the downloads folder of qbittorrent into another folder depending on category.(We support 2 categories as of now : movies and series)


