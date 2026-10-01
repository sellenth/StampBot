defmodule DragNStampWeb.PluginController do
  use DragNStampWeb, :controller

  def show(conn, _params),
    do:
      render_page(
        conn,
        "StampBot for ChatGPT",
        "Turn a YouTube link into chapters you can use.",
        [
          {"Ask for chapters",
           "Use StampBot in ChatGPT with a public YouTube video link. Ask for chapter markers, timestamped highlights, or chapters you can copy into a video description."},
          {"Follow the timestamps",
           "Completed results include a chapter list and links to those moments on YouTube. New videos are processed in the background; keep the job ID and ask ChatGPT to check it later."},
          {"Know what is shared",
           "Submitted video URLs and generated chapters are saved publicly on StampBot. Send public videos only. StampBot does not provide full transcripts, access private videos, edit videos, or post comments through this plugin."},
          {"Availability",
           "The ChatGPT plugin is in testing. It will become available in the public plugin directory after review and publication. You can already generate chapters on the StampBot website."}
        ]
      )

  def privacy(conn, _params),
    do:
      render_page(
        conn,
        "StampBot plugin privacy",
        "What StampBot receives when you use its ChatGPT plugin.",
        [
          {"Public submissions",
           "StampBot receives the YouTube video URL you submit and saves that URL, public video metadata, and generated chapters in its public feed. Do not submit a private or sensitive video. No ChatGPT conversation history is requested."},
          {"Video processing",
           "StampBot retrieves public YouTube video or caption information and sends the video URL or caption excerpts to Google's Gemini service to generate chapters. Requests are also subject to the policies of ChatGPT, YouTube, and Google."},
          {"Usage measurement",
           "StampBot stores the tool operation, time, result status, job reference, processing response time, and whether new processing was started. When ChatGPT supplies user or conversation identifier hints, they are stored as keyed hashes; transport identifiers are also hashed. Raw identifiers and conversation prompts are not stored in the plugin usage table. Standard service request logs may include the submitted public video URL."},
          {"Retention and requests",
           "Saved public results and usage records are retained to run the service and assess this experiment. If you want a submission or usage record reviewed or removed, contact the maintainer using the support page. Do not post private account identifiers in a public issue."}
        ]
      )

  def support(conn, _params),
    do:
      render_page(
        conn,
        "StampBot plugin support",
        "Help with chapter generation and saved results.",
        [
          {"Waiting for a video",
           "New videos can take several minutes. Keep the job ID and ask ChatGPT to check the saved result later. Repeatedly submitting the same link reuses the active job."},
          {"Unavailable results",
           "Private, deleted, restricted, or inaccessible videos may fail. Daily processing limits can also pause new requests; existing saved results remain available."},
          {"Report a problem",
           "Open an issue in the StampBot GitHub repository using the link below. Include a public video URL, job ID, and a description of the problem. Never include credentials, private videos, ChatGPT account identifiers, or conversation history."}
        ]
      )

  defp render_page(conn, title, intro, sections),
    do:
      render(put_root_layout(conn, false), :page,
        title: title,
        intro: intro,
        sections: sections,
        layout: false
      )
end
