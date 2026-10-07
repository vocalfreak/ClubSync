import { Controller } from "@hotwired/stimulus"

// THROWAWAY design test — dev only. The overlay drawer, no server round-trip: every
// field comes from #drawer-events, serialized once by Design::GridController. Never
// touches design_grid_controller.js.
//
// Captions are untrusted Instagram text, so every value goes in via textContent or a
// property assignment. innerHTML is not used anywhere in this file.
export default class extends Controller {
  static targets = [
    "content", "backdrop", "drawer", "frame", "track", "slidePrev", "slideNext", "dots",
    "title", "date", "venue", "handle", "instagram", "caption", "close", "copy",
    "fullscreen", "prev", "next"
  ]

  connect() {
    this.events = []
    this.cards = []
    this.index = -1
    this.opener = null
    this.fullscreen = false

    // Same root element as design_grid_controller.js, so this is the mode the grid uses.
    this.mode = this.element.dataset.designGridModeValue

    this.keyHandler = (event) => this.onKey(event)
    document.addEventListener("keydown", this.keyHandler)

    this.clickHandler = (event) => this.handleClick(event)
    this.element.addEventListener("click", this.clickHandler)

    // Stimulus connects this element the moment the parser inserts it, which is BEFORE
    // the drawer partial and #drawer-events further down this same subtree exist. Touching
    // a target in connect() throws "Missing target element", so nothing DOM-facing —
    // targets, payload or cards — may happen until the tree is actually complete. Even a
    // requestAnimationFrame can fire mid-parse, because the HTML parser yields to the event
    // loop while it works, so wait for the document to finish parsing.
    const setup = () => {
      this.backdropTarget.addEventListener("click", () => this.close())
      this.closeTarget.addEventListener("click", () => this.close())
      this.copyTarget.addEventListener("click", () => this.copyLink())
      this.fullscreenTarget.addEventListener("click", () => this.toggleFullscreen())
      this.prevTarget.addEventListener("click", () => this.step(-1))
      this.nextTarget.addEventListener("click", () => this.step(1))
      this.slidePrevTarget.addEventListener("click", () => this.slide(-1))
      this.slideNextTarget.addEventListener("click", () => this.slide(1))
      this.trackTarget.addEventListener("scroll", () => this.syncSlide(), { passive: true })

      // Reserve the scrollbar gutter up front so locking body scroll can't shift the grid.
      document.documentElement.style.scrollbarGutter = "stable"

      this.applyFrameShape()

      this.events = this.parseEvents()
      this.cards = Array.from(this.element.querySelectorAll("[data-event-id]"))

      const id = this.eventIdFromHash()
      if (id) this.open(id, null)
    }

    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", setup, { once: true })
    } else {
      setup()
    }
  }

  disconnect() {
    document.removeEventListener("keydown", this.keyHandler)
    this.element.removeEventListener("click", this.clickHandler)
    this.unlockScroll()
  }

  parseEvents() {
    const node = document.getElementById("drawer-events")
    if (!node) return []

    try {
      return JSON.parse(node.textContent)
    } catch (error) {
      console.error("design-drawer: could not parse #drawer-events", error)
      return []
    }
  }

  eventIdFromHash() {
    const match = location.hash.match(/^#event-(\d+)$/)
    if (!match) return null

    const id = Number(match[1])
    return this.events.some((event) => event.id === id) ? id : null
  }

  open(id, opener) {
    const index = this.events.findIndex((event) => event.id === id)
    if (index === -1) return

    this.index = index
    this.opener = opener || this.cards[index] || null
    this.render()
    history.replaceState(null, "", `#event-${id}`)

    // Locked after render so the drawer is measured at its natural width first.
    this.contentTarget.inert = true
    this.lockScroll()

    this.drawerTarget.inert = false
    this.drawerTarget.setAttribute("aria-hidden", "false")
    this.drawerTarget.classList.remove("translate-x-full", "pointer-events-none")
    this.backdropTarget.classList.remove("opacity-0", "pointer-events-none")
    this.closeTarget.focus()
  }

  close() {
    if (this.index === -1) return

    this.index = -1
    history.replaceState(null, "", location.pathname + location.search)

    this.drawerTarget.classList.add("translate-x-full", "pointer-events-none")
    this.backdropTarget.classList.add("opacity-0", "pointer-events-none")

    // inert comes off before focus moves, or focusing into an inert subtree is a no-op —
    // and the engine only recomputes inertness on the next frame, so focus has to wait.
    this.contentTarget.inert = false
    this.drawerTarget.inert = true
    this.drawerTarget.setAttribute("aria-hidden", "true")
    this.unlockScroll()

    const opener = this.opener
    this.opener = null
    requestAnimationFrame(() => opener?.focus())
  }

  onKey(event) {
    if (this.index === -1) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    } else if (event.key === "ArrowLeft") {
      event.preventDefault()
      this.step(-1)
    } else if (event.key === "ArrowRight") {
      event.preventDefault()
      this.step(1)
    }
  }

  step(delta) {
    const next = this.index + delta
    if (next < 0 || next >= this.events.length) return

    this.index = next
    this.render()
    history.replaceState(null, "", `#event-${this.events[this.index].id}`)
  }

  render() {
    const event = this.events[this.index]

    this.setText(this.titleTarget, event.title)
    this.setText(this.dateTarget, this.dateLine(event))
    this.setText(this.venueTarget, event.venue)
    this.setLink(this.handleTarget, event.handle ? `@${event.handle}` : null, this.handleUrl(event))
    this.setLink(this.instagramTarget, null, event.instagram_url)
    this.setText(this.captionTarget, event.caption)

    this.renderImages(event.images || [])
    this.renderBounds()
  }

  // A real <button> fires click on Enter and Space, so one delegated listener covers
  // mouse and keyboard.
  handleClick(event) {
    const card = event.target.closest("[data-event-id]")
    if (card) this.open(Number(card.dataset.eventId), card)
  }

  dateLine(event) {
    if (!event.starts_on) return ""

    // Parse as a bare date so the weekday can't slip across a UTC day boundary.
    const date = new Date(`${event.starts_on}T00:00:00`)
    const day = date.toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" })
    return event.starts_time ? `${day}, ${event.starts_time}` : day
  }

  handleUrl(event) {
    return event.handle ? `https://www.instagram.com/${event.handle}/` : null
  }

  setText(element, value) {
    element.textContent = value || ""
    element.classList.toggle("hidden", !value)
  }

  setLink(element, text, href) {
    if (!href) {
      element.textContent = ""
      element.classList.add("hidden")
      return
    }

    element.textContent = text || ""
    element.href = href
    element.classList.remove("hidden")
  }

  // Mirrors design_grid_controller.js: `square` swaps the poster's aspect-[4/5] for
  // aspect-square, every other mode keeps 4:5. Done once, since the mode only changes
  // with a page load. The frame deliberately does NOT carry data-design-grid-target="poster",
  // so the grid's own code never touches it.
  applyFrameShape() {
    if (this.mode !== "square") return

    this.frameTarget.classList.remove("aspect-[4/5]")
    this.frameTarget.classList.add("aspect-square")
  }

  // Same rule as the grid's fit(): `square` always covers, `hybrid` covers only when the
  // image's own ratio is 0.74–0.85 (close to 4:5), everything else contains.
  fitImage(image) {
    const ratio = image.naturalWidth / image.naturalHeight
    const cover =
      this.mode === "square" ||
      (this.mode === "hybrid" && ratio >= 0.74 && ratio <= 0.85)

    image.classList.toggle("object-cover", cover)
    image.classList.toggle("object-contain", !cover)
  }

  // Every slide fills the track, which fills the frame, so each image gets the same box
  // and the same fit as the index poster it came from.
  renderImages(urls) {
    this.trackTarget.replaceChildren()
    this.dotsTarget.replaceChildren()

    urls.forEach((url) => {
      const slide = document.createElement("div")
      slide.className = "h-full w-full shrink-0 snap-center"

      const image = document.createElement("img")
      image.alt = ""
      image.decoding = "async"
      image.className = "h-full w-full"

      // Fit needs the intrinsic size, so wait for the load unless it's already cached.
      // Listener goes on before src so a cached image can't fire its load event unheard.
      image.addEventListener("load", () => this.fitImage(image))
      image.src = url
      if (image.complete && image.naturalWidth > 0) this.fitImage(image)

      slide.append(image)
      this.trackTarget.append(slide)

      const dot = document.createElement("span")
      dot.className = "size-1.5 rounded-full bg-[#555555] transition-colors"
      this.dotsTarget.append(dot)
    })

    this.trackTarget.scrollLeft = 0
    this.syncSlide() // setting scrollLeft to 0 fires no scroll event if it was already 0
  }

  slide(delta) {
    const slide = this.trackTarget.clientWidth * delta
    this.trackTarget.scrollBy({ left: slide, behavior: "smooth" })
  }

  // Keeps the dots and the arrows in step with the track. Arrows are hidden at the ends
  // (like Instagram) and everything is hidden for a single image.
  syncSlide() {
    const count = this.trackTarget.children.length
    const width = this.trackTarget.clientWidth || 1
    const current = Math.min(Math.max(Math.round(this.trackTarget.scrollLeft / width), 0), Math.max(count - 1, 0))

    Array.from(this.dotsTarget.children).forEach((dot, n) => {
      dot.classList.toggle("bg-white", n === current)
      dot.classList.toggle("bg-[#555555]", n !== current)
    })

    this.dotsTarget.hidden = count < 2
    this.slidePrevTarget.hidden = count < 2 || current === 0
    this.slideNextTarget.hidden = count < 2 || current === count - 1
  }

  renderBounds() {
    const last = this.events.length - 1
    this.prevTarget.disabled = this.index === 0
    this.nextTarget.disabled = this.index === last
  }

  toggleFullscreen() {
    this.fullscreen = !this.fullscreen
    this.drawerTarget.classList.toggle("md:w-[550px]", !this.fullscreen)
  }

  copyLink() {
    // Clipboard access is refused whenever the document isn't focused or the permission was
    // denied, and that must not surface as an uncaught error in a throwaway test.
    navigator.clipboard?.writeText(location.href).catch(() => {})

    const label = this.copyLabelTarget
    const original = label.textContent
    label.textContent = "Copied"
    setTimeout(() => { label.textContent = original }, 1200)
  }

  lockScroll() {
    this.previousOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
  }

  unlockScroll() {
    if (this.previousOverflow === undefined) return

    document.body.style.overflow = this.previousOverflow
    this.previousOverflow = undefined
  }
}