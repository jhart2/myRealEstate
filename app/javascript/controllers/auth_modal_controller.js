import { Controller } from "@hotwired/stimulus"

// Airbnb-style centered auth modal (email → password progressive login + signup).
export default class extends Controller {
  static targets = [
    "overlay",
    "dialog",
    "emailStep",
    "passwordStep",
    "signupStep",
    "emailInput",
    "passwordEmail",
    "passwordInput",
    "signupEmail",
    "alert",
    "heading",
    "subtext"
  ]

  static values = {
    autoOpen: { type: String, default: "" },
    prefillEmail: { type: String, default: "" }
  }

  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    this.onExternalOpen = this.onExternalOpen.bind(this)

    document.addEventListener("keydown", this.onKeydown, true)
    document.addEventListener("auth-modal:open", this.onExternalOpen)

    if (this.prefillEmailValue && this.hasEmailInputTarget) {
      this.emailInputTarget.value = this.prefillEmailValue
    }

    if (this.autoOpenValue) {
      const mode = this.autoOpenValue
      this.open({ preventDefault() {}, params: { mode }, skipClearAlert: true })

      // Failed login: skip ahead to password with the email they tried.
      if (mode === "login" && this.prefillEmailValue) {
        if (this.hasPasswordEmailTarget) this.passwordEmailTarget.value = this.prefillEmailValue
        this.showPasswordStep()
        window.requestAnimationFrame(() => this.passwordInputTarget?.focus())
      }
    }
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown, true)
    document.removeEventListener("auth-modal:open", this.onExternalOpen)
    this.unlockScroll()
  }

  onExternalOpen(event) {
    const mode = event.detail?.mode || "login"
    const intent = event.detail?.intent
    this.open({ preventDefault() {}, params: { mode, intent } })
  }

  open(event) {
    event?.preventDefault?.()
    if (!this.hasOverlayTarget) return

    const mode = event?.params?.mode || "login"
    const intent = event?.params?.intent
    if (!event?.skipClearAlert) this.clearAlert()

    if (mode === "signup") {
      this.showSignup({ preventDefault() {}, skipClearAlert: true })
    } else {
      this.showEmailStep()
    }

    this.applyIntent(intent)

    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.setAttribute("aria-hidden", "false")
    this.lockScroll()

    window.requestAnimationFrame(() => {
      this.overlayTarget.classList.add("is-open")
      this.focusFirstField()
    })
  }

  close(event) {
    event?.preventDefault?.()
    if (!this.hasOverlayTarget || this.overlayTarget.classList.contains("hidden")) return

    this.overlayTarget.classList.remove("is-open")
    this.overlayTarget.setAttribute("aria-hidden", "true")

    window.setTimeout(() => {
      this.overlayTarget.classList.add("hidden")
      this.unlockScroll()
      this.showEmailStep()
      this.clearAlert()
      this.clearIntent()
    }, 180)
  }

  stop(event) {
    event.stopPropagation()
  }

  closeOnBackdrop(event) {
    if (event.target === this.overlayTarget) this.close(event)
  }

  onKeydown(event) {
    if (event.key !== "Escape") return
    if (!this.isOpen()) return

    event.preventDefault()
    event.stopImmediatePropagation()
    this.close()
  }

  continueWithEmail(event) {
    event.preventDefault()
    const email = (this.hasEmailInputTarget ? this.emailInputTarget.value : "").trim()
    if (!email) {
      this.showAlert("Enter your email address to continue.")
      this.emailInputTarget?.focus()
      return
    }

    if (this.hasPasswordEmailTarget) this.passwordEmailTarget.value = email
    if (this.hasSignupEmailTarget) this.signupEmailTarget.value = email
    this.clearAlert()
    this.showPasswordStep()
    window.requestAnimationFrame(() => this.passwordInputTarget?.focus())
  }

  backToEmail(event) {
    event?.preventDefault?.()
    this.clearAlert()
    this.showEmailStep()
    window.requestAnimationFrame(() => this.emailInputTarget?.focus())
  }

  showSignup(event) {
    event?.preventDefault?.()
    if (!event?.skipClearAlert) this.clearAlert()
    if (this.hasEmailInputTarget && this.hasSignupEmailTarget && this.emailInputTarget.value) {
      this.signupEmailTarget.value = this.emailInputTarget.value
    }
    this.emailStepTarget?.classList.add("hidden")
    this.passwordStepTarget?.classList.add("hidden")
    this.signupStepTarget?.classList.remove("hidden")
    if (this.hasHeadingTarget) this.headingTarget.textContent = "Create your account"
    window.requestAnimationFrame(() => {
      const first = this.signupStepTarget?.querySelector("input:not([type=hidden])")
      first?.focus()
    })
  }

  showLogin(event) {
    event?.preventDefault?.()
    this.clearAlert()
    this.showEmailStep()
    window.requestAnimationFrame(() => this.emailInputTarget?.focus())
  }

  isOpen() {
    return this.hasOverlayTarget && this.overlayTarget.classList.contains("is-open")
  }

  showEmailStep() {
    this.emailStepTarget?.classList.remove("hidden")
    this.passwordStepTarget?.classList.add("hidden")
    this.signupStepTarget?.classList.add("hidden")
    if (this.hasHeadingTarget) this.headingTarget.textContent = "Log in or sign up"
  }

  showPasswordStep() {
    this.emailStepTarget?.classList.add("hidden")
    this.passwordStepTarget?.classList.remove("hidden")
    this.signupStepTarget?.classList.add("hidden")
    if (this.hasHeadingTarget) this.headingTarget.textContent = "Welcome back"
  }

  applyIntent(intent) {
    if (!this.hasSubtextTarget) return
    if (intent === "save") {
      this.subtextTarget.hidden = false
      this.subtextTarget.textContent = "Sign in to save homes"
      this.subtextTarget.classList.remove("hidden")
    } else {
      this.clearIntent()
    }
  }

  clearIntent() {
    if (!this.hasSubtextTarget) return
    this.subtextTarget.textContent = ""
    this.subtextTarget.hidden = true
    this.subtextTarget.classList.add("hidden")
  }

  focusFirstField() {
    const visible = this.overlayTarget.querySelector(
      "[data-auth-modal-target='emailStep']:not(.hidden) input, " +
        "[data-auth-modal-target='passwordStep']:not(.hidden) input[type='password'], " +
        "[data-auth-modal-target='signupStep']:not(.hidden) input:not([type=hidden])"
    )
    visible?.focus()
  }

  showAlert(message) {
    if (!this.hasAlertTarget) return
    this.alertTarget.textContent = message
    this.alertTarget.classList.remove("hidden")
  }

  clearAlert() {
    if (!this.hasAlertTarget) return
    this.alertTarget.textContent = ""
    this.alertTarget.classList.add("hidden")
  }

  lockScroll() {
    document.documentElement.classList.add("auth-modal-open")
  }

  unlockScroll() {
    document.documentElement.classList.remove("auth-modal-open")
  }
}
