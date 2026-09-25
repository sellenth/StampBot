# AdSense setup

StampBot uses the existing Google publisher account `pub-8038077083732047`.
The website product was added to that account on September 25, 2026, with
`stamp-bot.com` registered as the site.

## Site verification

The root layout includes Google's `google-adsense-account` meta tag.
`priv/static/ads.txt` contains the account's Google seller record and is included
in the production static-file allowlist, so it is served at
<https://stamp-bot.com/ads.txt>.

After deploying, open the site's details in AdSense, select **Ads.txt snippet**,
confirm that the file is published, click **Verify**, and then **Request review**.
Google's review must finish before the site can show ads.

## Ad delivery

This initial integration only verifies ownership and declares the authorized
seller. It does not load the advertising script or request ads.

Before enabling ad delivery, publish the site's privacy disclosures and configure
the applicable consent messages in AdSense's **Privacy & messaging** section.
Then create a display ad unit, add its script and placement below the timestamp
results, and verify that LiveView updates do not initialize the same ad twice.
Keep live ad requests off in development and tests.

References:

- [Connect your site to AdSense](https://support.google.com/adsense/answer/7584263)
- [Upgrade an AdMob-linked account for website ads](https://support.google.com/adsense/answer/6023158)
