defmodule DragNStampWeb.PluginController do
  use DragNStampWeb, :controller

  def challenge(conn, _params) do
    conn =
      conn |> put_resp_content_type("text/plain") |> put_resp_header("cache-control", "no-store")

    case Application.get_env(:drag_n_stamp, :openai_apps_challenge) do
      token when is_binary(token) and byte_size(token) in 1..4096 -> send_resp(conn, 200, token)
      _ -> send_resp(conn, 404, "")
    end
  end

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

  def terms(conn, _params),
    do:
      render_page(
        conn,
        "StampBot plugin terms of use",
        "Conditions for using StampBot's public chapter service.",
        [
          {"Permitted use",
           "Use StampBot for public YouTube videos you are permitted to submit for processing. Respect applicable law and the rights of video creators. Do not use the service to access private videos, bypass access restrictions, or submit unlawful content."},
          {"Public results",
           "Submitting a link requests automated processing and public display of the video's URL, public metadata, and generated chapters on StampBot. Send public videos only. The privacy page explains processing and usage records."},
          {"Review generated chapters",
           "Chapters are generated automatically and can contain mistakes or omit important topics. Review timestamps and titles against the video before using or publishing them. The plugin does not edit videos or publish YouTube comments on your behalf."},
          {"Availability and limits",
           "This experimental plugin is free to use. Processing is subject to availability and shared daily limits, and requests may fail or be declined. Features and limits may change as the experiment develops."},
          {"Help and removal requests",
           "Use the support page to report problems or request review or removal of a public submission. Do not include credentials, private account identifiers, or conversation history in public support issues."}
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
