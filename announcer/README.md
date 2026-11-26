# Puppy Announcer

Post Puppy Admin / Puppy Companion announcements to your Discord channel.

1. In Discord: your channel > Edit Channel > Integrations > Webhooks > New Webhook > **Copy Webhook URL**.
2. Open `PuppyAnnouncer.exe`, paste the URL into **Webhook** and press **Save**. It is stored
   encrypted for your Windows user (`%APPDATA%\PuppyAnnouncer\settings.json`) and never shown again.
3. Write a title and message, or press **Puppy Admin update** / **Companion update** to fill one
   in from GitHub (the latest build or version and the changes since your last announcement).
4. Pick a colour and a ping (none, @here, @everyone, or a role id), then **Post to Discord**.
   **Preview** shows how it reads first.

Anyone with the webhook URL can post in that channel: keep it private. If it leaks, delete the
webhook in Discord and save a new one.
