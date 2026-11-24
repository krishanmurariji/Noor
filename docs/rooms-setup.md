# Rooms: one-time Firebase setup

Rooms (listen together) keep each room's shared state in a Firebase
Realtime Database. Noor talks to it over its REST API, with an anonymous
sign-in per phone. There is no Firebase SDK in the app. Until the two
settings below are in the build, the room panel says "Rooms are not set up
in this build of Noor yet."

1. **Create the project.** Open <https://console.firebase.google.com>,
   choose **Create a project**, name it (for example `noor-rooms`), and turn
   Google Analytics off. The free Spark plan is enough.
2. **Turn on anonymous sign-in.** Go to **Build → Authentication → Get
   started → Sign-in method → Anonymous → Enable → Save**.
3. **Create the database.** Go to **Build → Realtime Database → Create
   database**, pick the location closest to you, and start in **locked
   mode**.
4. **Paste the rules.** Open the database's **Rules** tab, replace
   everything with the contents of
   [`firebase/database.rules.json`](../firebase/database.rules.json), and
   press **Publish**.
5. **Copy the two settings:**
   - **Database URL:** shown at the top of the Realtime Database page, for
     example `https://noor-rooms-default-rtdb.asia-southeast1.firebasedatabase.app`.
   - **Web API key:** in **Project settings** (the gear) → **General**.
6. **Add them to GitHub.** Go to **Settings → Secrets and variables →
   Actions → New repository secret** and add `NOOR_FIREBASE_DB_URL` and
   `NOOR_FIREBASE_API_KEY`. The next release build picks them up.

Neither value is a password. Every Firebase app ships both inside the APK.
The rules decide who may read or write.

## What the rules allow

- Only people in a room can read it. Anyone signed in can read a room's
  name (`info`), so that "Ask to join" can show it.
- The star can change anything in their room: letting people in, removing
  or blocking them, the song, the queue, and handing over the star.
- Anyone else can only:
  - ask to join for themselves (not when blocked), or cancel the request;
  - leave, or update their own "still here" time;
  - ask for a song, or to be the star, in their own name.
- Room codes are six characters, and nothing lists all the rooms.

## Data

```
rooms/{CODE}/info      {name, star, starName, at}
            /members   {uid: {name, at, seen}}
            /knocks    {uid: {name, at, answer?}}   answer: "no" | "blocked"
            /blocked   {uid: name}
            /asks      {id: {kind: song|star, uid, name, song?, at}}
            /play      {song, pos, playing, at, phone?}
            /queue     [song, …]                    what plays next (max 20)
            /notes     {uid: {text, at}}            e.g. "Velvet Night plays next"
```
