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
    const setupBtn = document.getElementById('setup-btn')
    const usernameDisplay = document.getElementById('username-display')
    const usernameText = document.getElementById('username-text')
    const usernameForm = document.getElementById('username-form')
    const instructions = document.getElementById('instructions')
    const bookmarkletSection = document.getElementById('bookmarklet-section')
    const setUsernameBtn = document.getElementById('set-username-btn')
    const changeUsernameBtn = document.getElementById('change-username-btn')
    
    if (savedUsername) {
      if (setupBtn) setupBtn.classList.add('hidden')
      if (usernameDisplay) {
        usernameDisplay.classList.remove('hidden')
        usernameText.textContent = `Setup complete (${savedUsername})`
      }
      if (usernameForm) usernameForm.classList.add('hidden')
      if (instructions) instructions.classList.remove('hidden')
      if (bookmarkletSection) {
        bookmarkletSection.classList.remove('hidden')
        document.getElementById('current-username').textContent = savedUsername
      }
      this.updateBookmarkletWithUsername(savedUsername)
    }
    
    if (setUsernameBtn) {
      setUsernameBtn.addEventListener('click', () => {
        const usernameInput = document.getElementById('submitter-username')
        const username = usernameInput.value.trim()
        
        if (!username) {
          alert('Please enter a username')
          return
        }
        
        localStorage.setItem('drag-n-stamp-username', username)
        
        if (usernameForm) usernameForm.classList.add('hidden')
        if (instructions) instructions.classList.remove('hidden')
        if (bookmarkletSection) {
          bookmarkletSection.classList.remove('hidden')
          document.getElementById('current-username').textContent = username
        }
        if (usernameText) {
          usernameText.textContent = `Setup complete (${username})`
        }
        
        // Update the form username field
        const usernameField = document.getElementById('form-username')
        if (usernameField) {
          usernameField.value = username
        }
        
        this.updateBookmarkletWithUsername(username)
        alert(`Welcome ${username}! Use the bookmark tool below.`)
      })
    }
    
    if (changeUsernameBtn) {
      changeUsernameBtn.addEventListener('click', () => {
        if (usernameForm) usernameForm.classList.remove('hidden')
        if (instructions) instructions.classList.add('hidden')
        if (bookmarkletSection) bookmarkletSection.classList.add('hidden')
        
        const savedUsername = localStorage.getItem('drag-n-stamp-username')
        if (savedUsername) {
          document.getElementById('submitter-username').value = savedUsername
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
    // Update the hidden username field when the form is mounted
    this.updateUsernameField()
  },
  
  updateUsernameField() {
    const usernameField = document.getElementById('form-username')
    const savedUsername = localStorage.getItem('drag-n-stamp-username')
    if (usernameField) {
      usernameField.value = savedUsername || ''
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

