defmodule DragNStampWeb.InfoController do
  use DragNStampWeb, :controller

  def how_it_works(conn, _params),
    do:
      render_page(
        conn,
        "How StampBot works",
        "From a YouTube link to chapters you can paste into a description.",
        [
          {"1. Submit a public video",
           "Paste a public YouTube URL on the home page, in the browser extension, or through the ChatGPT plugin. Your submission is saved right away, so you can close the page and come back to check its progress."},
          {"2. The video is analyzed",
           "StampBot sends the video to Google's Gemini model, which watches it and identifies where topics change. When a video's captions are used instead, they are processed in excerpts that are checked individually, so a bad section can be retried without starting over."},
          {"3. Timing is validated",
           "Generated timestamps are checked for valid timing, and responses that fail the checks are retried a limited number of times before the result is saved."},
          {"4. Chapters are published",
           "The finished chapter list appears in the public feed and on its own page, with each timestamp linking to that moment on YouTube. Most videos take two to five minutes."},
          {"What it costs to run",
           "Every request is recorded with its estimated API cost, and shared daily budgets pause new processing before costs run away. Saved results stay available even when new submissions are paused."},
          {"Limitations",
           "StampBot cannot process private, deleted, or age-restricted videos. Chapters are generated automatically and can miss topics or mislabel a section, so review them before publishing them on your own video."}
        ]
      )

  def chapters_guide(conn, _params),
    do:
      render_page(
        conn,
        "A guide to YouTube chapters",
        "What YouTube requires for chapters, and how to write ones viewers actually use.",
        [
          {"What chapters do",
           "Chapters split a video's progress bar into labeled sections. Viewers can see what is coming, jump to the part they need, and come back later to a specific moment. Search engines can also show chapters as key moments in results."},
          {"YouTube's formatting rules",
           "Add timestamps to your video description, one per line. The first timestamp must be 0:00, there must be at least three, they must be listed in ascending order, and each chapter must be at least 10 seconds long. If any rule is broken, YouTube ignores the whole list."},
          {"Write titles people can scan",
           "A good chapter title says what happens, not just what it is called. \"Fixing the leaking valve\" helps a viewer more than \"Part 3\". Keep titles short, lead with the important words, and avoid repeating the video title."},
          {"Pick the right breaks",
           "Start a chapter where the topic actually changes, not at fixed intervals. A ten-minute video usually needs five to ten chapters. Very short sections are hard to click and make the progress bar noisy."},
          {"Check before you publish",
           "Click through every timestamp before saving. Automatic tools, including StampBot, can be a few seconds early or late at a topic change, and a chapter that starts mid-sentence feels sloppy."},
          {"Using StampBot's output",
           "Use the copy button on any StampBot result to grab the chapter list. Paste it into your description, confirm the first line is 0:00, adjust any titles you would phrase differently, and save."}
        ]
      )

  def about(conn, _params),
    do:
      render_page(
        conn,
        "About StampBot",
        "A small, independent tool for generating YouTube chapters.",
        [
          {"Who makes it",
           "StampBot is built and maintained by one independent developer. The source code is public on GitHub, and the service runs on a single small server with a fixed processing budget."},
          {"Is it free?",
           "Yes. Generating chapters is free and does not require an account. Shared daily limits keep costs predictable, so new submissions can be paused for a while on busy days."},
          {"Why are results public?",
           "Every result is added to a public feed so that anyone looking for chapters on the same video can reuse them instead of paying to generate them again. Leave the username blank to submit anonymously, and only submit public videos."},
          {"How accurate is it?",
           "Accuracy is usually good for talks, tutorials, and commentary with clear topic changes. It is weaker for music, gameplay without narration, and videos with long silent stretches. Always review chapters before publishing them."},
          {"Can I remove a submission?",
           "Yes. Open an issue on GitHub with the submission link and it will be removed. Do not include personal information in a public issue."},
          {"Contact",
           "Questions, bug reports, and removal requests go through GitHub issues using the link below."}
        ]
      )

  defp render_page(conn, title, intro, sections),
    do:
      conn
      |> put_root_layout(false)
      |> put_view(DragNStampWeb.PluginHTML)
      |> render(:page, title: title, intro: intro, sections: sections, layout: false)
end
