// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

let Hooks = {};

Hooks.LocalTime = {
  mounted() {
    this.render();
  },
  updated() {
    this.render();
  },
  render() {
    const iso = this.el.dataset.iso;
    const variant = this.el.dataset.variant || 'datetime';
    if (!iso) return;
    const dt = new Date(iso);
    if (isNaN(dt.getTime())) return;
    const dateOpts = { year: 'numeric', month: 'short', day: '2-digit' };
    const timeOpts = { hour: '2-digit', minute: '2-digit', hour12: true };
    if (variant === 'date') {
      this.el.textContent = dt.toLocaleDateString(undefined, dateOpts);
    } else {
      // default: datetime
      this.el.textContent = `${dt.toLocaleDateString(undefined, dateOpts)} ${dt.toLocaleTimeString(undefined, timeOpts)}`;
    }
    this.el.title = `UTC: ${iso}`;
  }
};

Hooks.UsernameSetup = {
  mounted() {
    const savedUsername = localStorage.getItem("drag-n-stamp-username");
    const usernameInputState = document.getElementById("username-input-state");
    const usernameDisplayState = document.getElementById(
      "username-display-state",
    );
    const currentUsernameDisplay = document.getElementById(
      "current-username-display",
    );
    const setUsernameBtn = document.getElementById("set-username-btn");
    const changeUsernameBtn = document.getElementById("change-username-btn");
    const submitterUsernameInput =
      document.getElementById("submitter-username");

    // Initialize state based on whether username exists
    if (savedUsername) {
      // Show display state
      if (usernameInputState) usernameInputState.classList.add("hidden");
      if (usernameDisplayState) {
        usernameDisplayState.classList.remove("hidden");
        if (currentUsernameDisplay)
          currentUsernameDisplay.textContent = savedUsername;
      }
      this.updateBookmarkletWithUsername(savedUsername);
    } else {
      // Show input state
      if (usernameInputState) usernameInputState.classList.remove("hidden");
      if (usernameDisplayState) usernameDisplayState.classList.add("hidden");
    }

    // Handle Set button click
    const handleSetUsername = () => {
      const username = submitterUsernameInput.value.trim();

      if (!username) {
        alert("Please enter a username");
        return;
      }

      // Save username
      localStorage.setItem("drag-n-stamp-username", username);

      // Switch to display state
      if (usernameInputState) usernameInputState.classList.add("hidden");
      if (usernameDisplayState) {
        usernameDisplayState.classList.remove("hidden");
        if (currentUsernameDisplay)
          currentUsernameDisplay.textContent = username;
      }

      // Update the form username field if it exists (for other pages)
      const usernameField = document.getElementById("form-username");
      if (usernameField) {
        usernameField.value = username;
      }

      // Update bookmarklet
      this.updateBookmarkletWithUsername(username);

      // Clear input
      submitterUsernameInput.value = "";
    };

    if (setUsernameBtn) {
      setUsernameBtn.addEventListener("click", handleSetUsername);
    }

    // Handle Enter key press on username input
    if (submitterUsernameInput) {
      submitterUsernameInput.addEventListener("keypress", (e) => {
        if (e.key === "Enter") {
          handleSetUsername();
        }
      });
    }

    // Handle Change Username button click
    if (changeUsernameBtn) {
      changeUsernameBtn.addEventListener("click", () => {
        // Switch to input state
        if (usernameInputState) usernameInputState.classList.remove("hidden");
        if (usernameDisplayState) usernameDisplayState.classList.add("hidden");

        // Pre-fill with current username
        const currentUsername = localStorage.getItem("drag-n-stamp-username");
        if (currentUsername && submitterUsernameInput) {
          submitterUsernameInput.value = currentUsername;
        }
      });
    }
  },

  updateBookmarkletWithUsername(submitterUsername) {
    const textarea = document.getElementById("bookmarklet-code");
    const bookmarkletLink = document.querySelector('a[draggable="true"]');

    if (textarea && bookmarkletLink) {
      let code = textarea.value;
      code = code.replace(
        /body:JSON\.stringify\({([^}]+)}\)/,
        `body:JSON.stringify({$1,submitter_username:'${submitterUsername}'})`,
      );

      textarea.value = code;
      bookmarkletLink.href = code;
    }
  },
};

Hooks.BookmarkletCode = {
  mounted() {
    const copyBtn = document.getElementById("copy-bookmarklet-btn");
    if (copyBtn) {
      copyBtn.addEventListener("click", () => {
        const textarea = document.getElementById("bookmarklet-code");
        textarea.select();
        textarea.setSelectionRange(0, 99999);
        navigator.clipboard
          .writeText(textarea.value)
          .then(() => {
            alert("Bookmarklet copied to clipboard!");
          })
          .catch(() => {
            alert("Failed to copy. Please copy manually.");
          });
      });
    }
  },
};

Hooks.UrlForm = {
  mounted() {
    // Update the username field when the form is mounted
    this.updateUsernameField();
  },

  updateUsernameField() {
    // Update both visible username field and hidden field if they exist
    const visibleUsernameField = document.querySelector(
      'input[name="username"]',
    );
    const hiddenUsernameField = document.getElementById("form-username");
    const savedUsername = localStorage.getItem("drag-n-stamp-username");

    if (visibleUsernameField && savedUsername) {
      visibleUsernameField.value = savedUsername;
    }

    if (hiddenUsernameField) {
      hiddenUsernameField.value = savedUsername || "";
    }
  },
};

Hooks.ClickableTimestamps = {
  mounted() {
    this.makeTimestampsClickable();
  },

  updated() {
    this.makeTimestampsClickable();
  },

  makeTimestampsClickable() {
    const videoUrl = this.el.dataset.videoUrl;
    const timestampText = this.el.textContent;
    
    // Parse timestamps in format like "0:30", "1:25", "12:45", etc.
    // Must be at start of line, after whitespace, or after common timestamp prefixes
    // Avoid matching times with AM/PM or other text suffixes
    const timestampRegex = /(^|\s)(\d{1,2}:\d{2})(?!\s*[AP]M|[a-zA-Z])/gm;
    
    let htmlContent = timestampText;
    let match;
    
    while ((match = timestampRegex.exec(timestampText)) !== null) {
      const fullMatch = match[0];  // Full match including whitespace
      const prefix = match[1];     // Whitespace or start of line
      const timestamp = match[2];  // The actual timestamp
      const seconds = this.timestampToSeconds(timestamp);
      
      if (seconds !== null) {
        const clickableTimestamp = this.createClickableTimestamp(videoUrl, timestamp, seconds);
        const replacement = prefix + clickableTimestamp;
        htmlContent = htmlContent.replace(fullMatch, replacement);
      }
    }
    
    // Only update if we found timestamps
    if (htmlContent !== timestampText) {
      this.el.innerHTML = htmlContent;
    }
  },

  timestampToSeconds(timestamp) {
    const parts = timestamp.split(':').map(Number);
    if (parts.length === 2 && !parts.some(isNaN)) {
      return parts[0] * 60 + parts[1];
    }
    return null;
  },

  createClickableTimestamp(videoUrl, timestamp, seconds) {
    // Create URL with timestamp parameter
    const url = new URL(videoUrl);
    url.searchParams.set('t', `${seconds}s`);
    
    return `<a href="${url.href}" target="_blank" rel="noopener noreferrer" class="clickable-timestamp" title="Jump to ${timestamp}">${timestamp}</a>`;
  }
};

Hooks.WebGLBackground = {
  mounted() {
    const canvas = this.el;
    const gl = canvas.getContext("webgl");

    if (!gl) {
      console.warn("WebGL not supported");
      return;
    }

    // Vertex shader source
    const vertexShaderSource = `
      attribute vec4 a_position;
      varying vec2 v_texCoord;

      void main() {
        gl_Position = a_position;
        v_texCoord = (a_position.xy + 1.0) * 0.5;
      }
    `;

    // Fragment shader source - black and white animated pattern
    const fragmentShaderSource = `
      precision mediump float;
      uniform float u_time;
      uniform vec2 u_resolution;
      varying vec2 v_texCoord;

      float noise(vec2 st) {
        return fract(sin(dot(st.xy, vec2(12.9898,78.233))) * 43758.5453123);
      }

      float smoothNoise(vec2 st) {
        vec2 i = floor(st);
        vec2 f = fract(st);

        float a = noise(i);
        float b = noise(i + vec2(1.0, 0.0));
        float c = noise(i + vec2(0.0, 1.0));
        float d = noise(i + vec2(1.0, 1.0));

        vec2 u = f * f * (3.0 - 2.0 * f);

        return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
      }

      void main() {
        vec2 st = v_texCoord * 8.0;

        // Moving noise pattern
        st.x += sin(u_time * 0.8) * 0.5;
        st.y += cos(u_time * 1.0) * 0.3;

        float n = smoothNoise(st);

        // Add some wave patterns
        n += sin(v_texCoord.x * 20.0 + u_time) * 0.1;
        n += cos(v_texCoord.y * 15.0 + u_time * 0.7) * 0.1;

        // Create contrast
        n = smoothstep(0.3, 0.7, n);

        gl_FragColor = vec4(vec3(n), 0.8);
      }
    `;

    function createShader(gl, type, source) {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);

      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        console.error("Shader compile error:", gl.getShaderInfoLog(shader));
        gl.deleteShader(shader);
        return null;
      }

      return shader;
    }

    function createProgram(gl, vertexShader, fragmentShader) {
      const program = gl.createProgram();
      gl.attachShader(program, vertexShader);
      gl.attachShader(program, fragmentShader);
      gl.linkProgram(program);

      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        console.error("Program link error:", gl.getProgramInfoLog(program));
        gl.deleteProgram(program);
        return null;
      }

      return program;
    }

    const vertexShader = createShader(gl, gl.VERTEX_SHADER, vertexShaderSource);
    const fragmentShader = createShader(
      gl,
      gl.FRAGMENT_SHADER,
      fragmentShaderSource,
    );
    const program = createProgram(gl, vertexShader, fragmentShader);

    if (!program) return;

    // Create buffer for full-screen quad
    const positionBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
      gl.STATIC_DRAW,
    );

    const positionLocation = gl.getAttribLocation(program, "a_position");
    const timeLocation = gl.getUniformLocation(program, "u_time");
    const resolutionLocation = gl.getUniformLocation(program, "u_resolution");

    let startTime = Date.now();

    const render = () => {
      const currentTime = (Date.now() - startTime) / 1000;

      // Set canvas size
      canvas.width = canvas.offsetWidth;
      canvas.height = canvas.offsetHeight;
      gl.viewport(0, 0, canvas.width, canvas.height);

      // Clear and use program
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(program);

      // Set uniforms
      gl.uniform1f(timeLocation, currentTime);
      gl.uniform2f(resolutionLocation, canvas.width, canvas.height);

      // Set up attributes
      gl.enableVertexAttribArray(positionLocation);
      gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
      gl.vertexAttribPointer(positionLocation, 2, gl.FLOAT, false, 0, 0);

      // Draw
      gl.drawArrays(gl.TRIANGLES, 0, 6);

      requestAnimationFrame(render);
    };

    // Handle resize
    const resizeObserver = new ResizeObserver(() => {
      canvas.width = canvas.offsetWidth;
      canvas.height = canvas.offsetHeight;
    });
    resizeObserver.observe(canvas);

    render();

    // Cleanup on destroyed
    this.handleEvent = this.handleEvent || {};
    this.destroyed = () => {
      resizeObserver.disconnect();
    };
  },

  destroyed() {
    if (this.destroyed) this.destroyed();
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// Dark mode functionality
function toggleTheme() {
  const currentTheme = document.documentElement.getAttribute("data-theme");
  const newTheme = currentTheme === "dark" ? "light" : "dark";

  document.documentElement.setAttribute("data-theme", newTheme);
  localStorage.setItem("theme", newTheme);

  // Match browser UI (status bar) color
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', newTheme === 'dark' ? '#0b0f14' : '#ffffff');

  // Update icon
  const icon = document.getElementById("theme-icon");
  if (icon) {
    icon.textContent = newTheme === "dark" ? "☀️" : "🌙";
  }
}

// Initialize theme on page load
document.addEventListener("DOMContentLoaded", function () {
  const savedTheme = localStorage.getItem("theme");

  // Use saved theme or browser preference
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  const theme = savedTheme || (prefersDark ? "dark" : "light");

  document.documentElement.setAttribute("data-theme", theme);

  // Ensure theme-color stays in sync on initial load (for Safari/iOS)
  const metaTheme = document.querySelector('meta[name="theme-color"]');
  if (metaTheme) metaTheme.setAttribute('content', theme === 'dark' ? '#0b0f14' : '#ffffff');

  // Update icon
  const icon = document.getElementById("theme-icon");
  if (icon) {
    icon.textContent = theme === "dark" ? "☀️" : "🌙";
  }
});

// Make toggleTheme globally available
window.toggleTheme = toggleTheme;

// Copy to clipboard function
function copyToClipboard(elementId) {
  const element = document.getElementById(elementId);
  if (!element) return;
  
  const text = element.textContent || element.innerText;
  
  navigator.clipboard.writeText(text).then(() => {
    // Show success feedback
    const copyBtn = document.querySelector(`button[onclick*="${elementId}"]`);
    if (copyBtn) {
      const originalText = copyBtn.innerHTML;
      copyBtn.innerHTML = '✓';
      copyBtn.style.color = '#10b981';
      
      setTimeout(() => {
        copyBtn.innerHTML = originalText;
        copyBtn.style.color = '';
      }, 1500);
    }
  }).catch(err => {
    console.error('Failed to copy:', err);
    // Fallback for older browsers
    try {
      const textArea = document.createElement('textarea');
      textArea.value = text;
      document.body.appendChild(textArea);
      textArea.select();
      document.execCommand('copy');
      document.body.removeChild(textArea);
      
      // Show success feedback
      const copyBtn = document.querySelector(`button[onclick*="${elementId}"]`);
      if (copyBtn) {
        const originalText = copyBtn.innerHTML;
        copyBtn.innerHTML = '✓';
        copyBtn.style.color = '#10b981';
        
        setTimeout(() => {
          copyBtn.innerHTML = originalText;
          copyBtn.style.color = '';
        }, 1500);
      }
    } catch (err) {
      alert('Failed to copy to clipboard');
    }
  });
}

// Make copyToClipboard globally available
window.copyToClipboard = copyToClipboard;
