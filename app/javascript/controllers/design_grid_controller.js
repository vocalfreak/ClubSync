import { Controller } from "@hotwired/stimulus"

// THROWAWAY design test — dev only. Decides each poster's fit from its real
// intrinsic dimensions on load, since the images keep their native ratio and we
// only store bytes. Tally so the split is visible without opening devtools.
export default class extends Controller {
  static values = { mode: String }
  static targets = [ "poster", "cover", "contain" ]

  connect() {
    this.coverCount = 0
    this.containCount = 0

    if (this.modeValue === "square") {
      this.posterTargets.forEach((poster) => {
        poster.classList.remove("aspect-[4/5]")
        poster.classList.add("aspect-square")
      })
    }

    // Images are loading="lazy", so a card below the fold has not been fetched yet and
    // has nothing to fit. fit() runs from the load event, which covers both cases.
    this.element.querySelectorAll("img").forEach((image) => {
      if (image.complete && image.naturalWidth > 0) {
        this.fit(image)
      } else {
        image.addEventListener("load", () => this.fit(image))
      }
    })
  }

  fit(image) {
    const ratio = image.naturalWidth / image.naturalHeight
    const cover =
      this.modeValue === "square" ||
      (this.modeValue === "hybrid" && ratio >= 0.74 && ratio <= 0.85)

    image.classList.toggle("object-cover", cover)
    image.classList.toggle("object-contain", !cover)

    cover ? this.coverCount++ : this.containCount++
    this.render()
  }

  render() {
    this.coverTargets.forEach((element) => { element.textContent = this.coverCount })
    this.containTargets.forEach((element) => { element.textContent = this.containCount })
  }
}