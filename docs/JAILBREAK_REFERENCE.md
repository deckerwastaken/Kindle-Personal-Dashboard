# Jailbreak reference (what this project was built and tested against)

This project needs a **jailbroken** Kindle — "jailbroken" means the device's normal
software restrictions have been removed, so it can run programs Amazon didn't put
there itself (like KOReader and this dashboard). Jailbreaking is **not part of this
project** — it's a well-documented, actively-maintained process owned by the Kindle
modding community, and doing it wrong can leave your device unusable, so it deserves
its own careful, up-to-date guide rather than a copy pasted in here that could go stale.

**Start here for jailbreaking**: [kindlemodding.org](https://kindlemodding.org) — the
current, actively-maintained community hub for Kindle jailbreaking, covering every
supported device and firmware version, not just the one below.

> **Disclaimer**: this page documents and links to a third-party jailbreak process —
> it doesn't host, distribute, or endorse any jailbreak tool, and jailbreaking your
> own device is your decision and your risk. It can void your warranty, and the legal
> status of device jailbreaking varies by jurisdiction, so check what applies where you
> are before proceeding.

## What this specific project was built and tested against

So you can sanity-check whether your own device is a close match before you start:

- **Model**: Kindle 7th Generation (2014), model **WP63GW** ("KT2" hardware, in the
  community's naming convention)
- **Firmware at jailbreak time**: 5.12.2.2
- **Screen**: 600 x 800px, 167 PPI, 16-level grayscale, no frontlight, 4GB storage

If your Kindle is a different model or firmware version, the dashboard itself may
still work once jailbroken (it doesn't depend on this specific hardware in any deep
way), but the exact jailbreak method below won't necessarily apply — check
kindlemodding.org's own compatibility chart for your device first.

## The method that worked for this device: WinterBreak2

This project's device was jailbroken using **WinterBreak2**, which (at the time)
worked on firmware below 5.16.4, required no Amazon account registration, and no
"demo mode" trickery.

1. Free up storage on the device until at least 50–90MB is free (this blocks Amazon
   from silently auto-updating the firmware out from under you mid-jailbreak).
2. Follow kindlemodding.org's own
   [prevent-auto-update guide](https://kindlemodding.org/jailbreaking/prevent-auto-update/)
   as an extra safeguard.
3. Copy the WinterBreak2 files (`jb.sh`, `patchedUks.sqsh`, and the `winterbreak2`
   folder) to the root of the Kindle's storage over USB.
4. On the Kindle, open the Experimental Browser and navigate to
   `https://winterbreak2.now.sh/`.
5. Tap **Jailbreak**, then turn on Airplane Mode immediately afterward (before the
   device has a chance to phone home to Amazon).

If this exact tool is no longer current by the time you're reading this,
kindlemodding.org will have whatever the up-to-date equivalent is — that site, not
this document, is the source of truth for jailbreaking itself.

## After jailbreaking: getting KUAL and KOReader on

This dashboard runs standalone (see `kindle-daemon/README.md` for why), but still
needs **KUAL** (a launcher menu for jailbroken Kindles) and **KOReader** (an e-reader
app this project borrows a couple of binaries from — `fbink` for drawing to the
screen, and `luajit` to actually run the dashboard code) installed first:

1. **Hotfix** (a small compatibility patch some jailbreak tools need): download
   `Update_hotfix_universal.bin` from
   [github.com/KindleModding/Hotfix/releases](https://github.com/KindleModding/Hotfix/releases),
   place it at the root of the Kindle's storage, then on the device go to
   Settings → **Update Your Kindle** — it applies automatically from the local file,
   no internet connection needed for this step.
2. **KUAL**: install via **PEKI** (the current community-preferred installer method).
   Follow kindlemodding.org's KUAL installation guide for the exact current steps.
3. **KOReader**: download the `kindlepw2` package matching your firmware from
   [koreader.rocks](https://koreader.rocks) (or kindlemodding.org's linked mirror),
   copy the `koreader` folder to the root of the Kindle's storage, and copy the
   `extensions` folder's contents into the Kindle's own `extensions` folder. It
   should then appear as an option inside KUAL.

Once KUAL and KOReader are both installed and working, you're ready to continue with
this project's own setup — see `docs/LAUNCH_GUIDE.md`.
