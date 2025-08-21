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
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

Hooks.UsernameSetup = {
  mounted() {
    const savedUsername = localStorage.getItem('drag-n-stamp-username')
    const usernameInputState = document.getElementById('username-input-state')
    const usernameDisplayState = document.getElementById('username-display-state')
    const currentUsernameDisplay = document.getElementById('current-username-display')
    const setUsernameBtn = document.getElementById('set-username-btn')
    const changeUsernameBtn = document.getElementById('change-username-btn')
    const submitterUsernameInput = document.getElementById('submitter-username')
    
    // Initialize state based on whether username exists
    if (savedUsername) {
      // Show display state
      if (usernameInputState) usernameInputState.classList.add('hidden')
      if (usernameDisplayState) {
        usernameDisplayState.classList.remove('hidden')
        if (currentUsernameDisplay) currentUsernameDisplay.textContent = savedUsername
      }
      this.updateBookmarkletWithUsername(savedUsername)
    } else {
      // Show input state
      if (usernameInputState) usernameInputState.classList.remove('hidden')
      if (usernameDisplayState) usernameDisplayState.classList.add('hidden')
    }
    
    // Handle Set button click
    if (setUsernameBtn) {
      setUsernameBtn.addEventListener('click', () => {
        const username = submitterUsernameInput.value.trim()
        
        if (!username) {
          alert('Please enter a username')
          return
        }
        
        // Save username
        localStorage.setItem('drag-n-stamp-username', username)
        
        // Switch to display state
        if (usernameInputState) usernameInputState.classList.add('hidden')
        if (usernameDisplayState) {
          usernameDisplayState.classList.remove('hidden')
          if (currentUsernameDisplay) currentUsernameDisplay.textContent = username
        }
        
        // Update the form username field if it exists (for other pages)
        const usernameField = document.getElementById('form-username')
        if (usernameField) {
          usernameField.value = username
        }
        
        // Update bookmarklet
        this.updateBookmarkletWithUsername(username)
        
        // Clear input
        submitterUsernameInput.value = ''
      })
    }
    
    // Handle Change Username button click
    if (changeUsernameBtn) {
      changeUsernameBtn.addEventListener('click', () => {
        // Switch to input state
        if (usernameInputState) usernameInputState.classList.remove('hidden')
        if (usernameDisplayState) usernameDisplayState.classList.add('hidden')
        
        // Pre-fill with current username
        const currentUsername = localStorage.getItem('drag-n-stamp-username')
        if (currentUsername && submitterUsernameInput) {
          submitterUsernameInput.value = currentUsername
        }
      })
    }
  },
  
  updateBookmarkletWithUsername(submitterUsername) {
    const textarea = document.getElementById('bookmarklet-code')
    const bookmarkletLink = document.querySelector('a[draggable="true"]')
    
    if (textarea && bookmarkletLink) {
      let code = textarea.value
      code = code.replace(
        /body:JSON\.stringify\({([^}]+)}\)/,
        `body:JSON.stringify({$1,submitter_username:'${submitterUsername}'})`
      )
      
      textarea.value = code
      bookmarkletLink.href = code
    }
  }
}

Hooks.BookmarkletCode = {
  mounted() {
    const copyBtn = document.getElementById('copy-bookmarklet-btn')
    if (copyBtn) {
      copyBtn.addEventListener('click', () => {
        const textarea = document.getElementById('bookmarklet-code')
        textarea.select()
        textarea.setSelectionRange(0, 99999)
        navigator.clipboard.writeText(textarea.value).then(() => {
          alert('Bookmarklet copied to clipboard!')
        }).catch(() => {
          alert('Failed to copy. Please copy manually.')
        })
      })
    }
  }
}

Hooks.UrlForm = {
  mounted() {
    // Update the username field when the form is mounted
    this.updateUsernameField()
  },
  
  updateUsernameField() {
    // Update both visible username field and hidden field if they exist
    const visibleUsernameField = document.querySelector('input[name="username"]')
    const hiddenUsernameField = document.getElementById('form-username')
    const savedUsername = localStorage.getItem('drag-n-stamp-username')
    
    if (visibleUsernameField && savedUsername) {
      visibleUsernameField.value = savedUsername
    }
    
    if (hiddenUsernameField) {
      hiddenUsernameField.value = savedUsername || ''
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Dark mode functionality
function toggleTheme() {
  const currentTheme = document.documentElement.getAttribute('data-theme')
  const newTheme = currentTheme === 'dark' ? 'light' : 'dark'
  
  document.documentElement.setAttribute('data-theme', newTheme)
  localStorage.setItem('theme', newTheme)
  
  // Update icon
  const icon = document.getElementById('theme-icon')
  if (icon) {
    icon.textContent = newTheme === 'dark' ? '☀️' : '🌙'
  }
}

// Initialize theme on page load
document.addEventListener('DOMContentLoaded', function() {
  const savedTheme = localStorage.getItem('theme')
  
  // Use saved theme or browser preference
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches
  const theme = savedTheme || (prefersDark ? 'dark' : 'light')
  
  document.documentElement.setAttribute('data-theme', theme)
  
  // Update icon
  const icon = document.getElementById('theme-icon')
  if (icon) {
    icon.textContent = theme === 'dark' ? '☀️' : '🌙'
  }
})

// Make toggleTheme globally available
window.toggleTheme = toggleTheme

