import {
  type Bytes,
  encodePointer,
  encodeScroll,
  PointerAction,
  PointerButton,
  PointerTool,
  ScrollPhase,
  ScrollUnit,
} from '../protocol';
import { clamp01, normalize, type Point, type Rect } from './geometry';
import { TouchGestures, type TouchSample } from './touch';

export interface InputTarget {
  /** Where the video is, in client coordinates. */
  videoRect(): Rect;
  /** False while there is no stream to control. */
  enabled(): boolean;
  send(bytes: Bytes): void;
}

// DOM `buttons` bits → protocol buttons.
const mouseButtons: ReadonlyArray<[bit: number, button: PointerButton]> = [
  [1, PointerButton.left],
  [2, PointerButton.right],
  [4, PointerButton.middle],
];

/** Mouse, pen and touch on the video surface, plus the wheel. */
export class PointerInput {
  private readonly gestures: TouchGestures;
  private readonly rawUpdates: boolean;
  private mouseState = 0;
  private lastMouse: Point | null = null;
  private penButton: PointerButton | null = null;

  constructor(
    private readonly surface: HTMLElement,
    private readonly target: InputTarget,
  ) {
    this.gestures = new TouchGestures({
      pointer: (action, button, x, y) => this.sendPointer(action, button, PointerTool.finger, { x, y }, 1),
      scroll: (phase, x, y, dx, dy) =>
        this.target.send(encodeScroll(phase, ScrollUnit.normalized, clamp01(x), clamp01(y), dx, dy)),
    });
    // pointerrawupdate isn't aligned to animation frames: lower mouse latency where supported.
    this.rawUpdates = 'onpointerrawupdate' in window;

    surface.addEventListener('pointerdown', this.onDown);
    surface.addEventListener('pointermove', this.onMove);
    if (this.rawUpdates) surface.addEventListener('pointerrawupdate', this.onRawUpdate as EventListener);
    surface.addEventListener('pointerup', this.onUp);
    surface.addEventListener('pointercancel', this.onCancel);
    surface.addEventListener('lostpointercapture', this.onLostCapture);
    surface.addEventListener('wheel', this.onWheel, { passive: false });
    surface.addEventListener('contextmenu', (event) => event.preventDefault());
    // iOS Safari: no pinch zoom, magnifier or double-tap zoom on the video.
    surface.addEventListener('gesturestart', (event) => event.preventDefault());
    surface.addEventListener('touchstart', (event) => event.preventDefault(), { passive: false });
    surface.addEventListener('touchmove', (event) => event.preventDefault(), { passive: false });
  }

  /** Forgets pressed buttons and touches, e.g. after the stream stopped. */
  reset(): void {
    this.mouseState = 0;
    this.lastMouse = null;
    this.penButton = null;
    this.gestures.reset();
  }

  private point(event: PointerEvent): Point {
    return normalize(this.target.videoRect(), event.clientX, event.clientY);
  }

  private sendPointer(action: PointerAction, button: PointerButton, tool: PointerTool, point: Point, pressure: number): void {
    const x = clamp01(point.x);
    const y = clamp01(point.y);
    if (tool === PointerTool.mouse && action === PointerAction.move) {
      // Down / up handlers re-send the position; skip it when the cursor is already there.
      if (this.lastMouse && this.lastMouse.x === x && this.lastMouse.y === y) return;
      this.lastMouse = { x, y };
    }
    this.target.send(encodePointer(action, button, tool, x, y, pressure));
  }

  private touchSample(event: PointerEvent, point = this.point(event)): TouchSample {
    return { id: event.pointerId, clientX: event.clientX, clientY: event.clientY, x: point.x, y: point.y, time: event.timeStamp };
  }

  private readonly onDown = (event: PointerEvent) => {
    if (!this.target.enabled()) return;
    event.preventDefault();
    this.surface.setPointerCapture?.(event.pointerId);
    switch (event.pointerType) {
      case 'touch':
        this.gestures.down(this.touchSample(event));
        break;
      case 'pen': {
        const point = this.point(event);
        // Barrel button held while touching down: secondary click.
        this.penButton = event.buttons & 2 ? PointerButton.right : PointerButton.left;
        this.sendPointer(PointerAction.move, PointerButton.left, PointerTool.stylus, point, event.pressure);
        this.sendPointer(PointerAction.down, this.penButton, PointerTool.stylus, point, event.pressure || 1);
        break;
      }
      default:
        this.sendPointer(PointerAction.move, PointerButton.left, PointerTool.mouse, this.point(event), 1);
        this.syncMouseButtons(event);
        break;
    }
  };

  private readonly onMove = (event: PointerEvent) => {
    if (!this.target.enabled()) return;
    switch (event.pointerType) {
      case 'touch':
        this.gestures.move(this.touchSample(event));
        break;
      case 'pen': {
        // Coalesced samples keep fast strokes smooth (pens report at up to 240 Hz).
        const samples = this.penButton !== null && event.getCoalescedEvents ? event.getCoalescedEvents() : [];
        for (const sample of samples.length ? samples : [event]) {
          const pressure = this.penButton !== null ? sample.pressure || 1 : 0;
          this.sendPointer(PointerAction.move, PointerButton.left, PointerTool.stylus, this.point(sample), pressure);
        }
        break;
      }
      default:
        if (!this.rawUpdates) {
          this.sendPointer(PointerAction.move, PointerButton.left, PointerTool.mouse, this.point(event), 1);
        }
        // Chorded button changes arrive as pointermove.
        this.syncMouseButtons(event);
        break;
    }
  };

  private readonly onRawUpdate = (event: PointerEvent) => {
    if (event.pointerType !== 'mouse' || !this.target.enabled()) return;
    this.sendPointer(PointerAction.move, PointerButton.left, PointerTool.mouse, this.point(event), 1);
    this.syncMouseButtons(event);
  };

  private readonly onUp = (event: PointerEvent) => {
    if (!this.target.enabled()) return;
    switch (event.pointerType) {
      case 'touch':
        this.gestures.up(this.touchSample(event));
        break;
      case 'pen':
        if (this.penButton !== null) {
          this.sendPointer(PointerAction.up, this.penButton, PointerTool.stylus, this.point(event), 0);
          this.penButton = null;
        }
        break;
      default:
        this.sendPointer(PointerAction.move, PointerButton.left, PointerTool.mouse, this.point(event), 1);
        this.syncMouseButtons(event);
        break;
    }
  };

  private readonly onCancel = (event: PointerEvent) => {
    switch (event.pointerType) {
      case 'touch':
        this.gestures.cancel(this.touchSample(event));
        break;
      case 'pen':
        if (this.penButton !== null) {
          this.sendPointer(PointerAction.cancel, this.penButton, PointerTool.stylus, this.point(event), 0);
          this.penButton = null;
        }
        break;
      default:
        this.releaseMouse(event);
        break;
    }
  };

  private readonly onLostCapture = (event: PointerEvent) => {
    // E.g. the window lost focus mid-drag: don't leave a button stuck down on the Mac.
    if (event.pointerType === 'mouse' && event.buttons === 0) this.releaseMouse(event);
  };

  private releaseMouse(event: PointerEvent): void {
    const point = this.point(event);
    for (const [bit, button] of mouseButtons) {
      if (this.mouseState & bit) this.sendPointer(PointerAction.up, button, PointerTool.mouse, point, 0);
    }
    this.mouseState = 0;
  }

  private syncMouseButtons(event: PointerEvent): void {
    const next = event.buttons & 7;
    if (next === this.mouseState) return;
    const point = this.point(event);
    for (const [bit, button] of mouseButtons) {
      const was = this.mouseState & bit;
      const is = next & bit;
      if (is && !was) this.sendPointer(PointerAction.down, button, PointerTool.mouse, point, 1);
      else if (was && !is) this.sendPointer(PointerAction.up, button, PointerTool.mouse, point, 0);
    }
    this.mouseState = next;
  }

  private readonly onWheel = (event: WheelEvent) => {
    event.preventDefault();
    if (!this.target.enabled()) return;
    const rect = this.target.videoRect();
    const point = normalize(rect, event.clientX, event.clientY);
    let unit: ScrollUnit = ScrollUnit.normalized;
    let dx: number;
    let dy: number;
    // Wheel deltas are positive when the content should move up; the protocol is the reverse.
    if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) {
      unit = ScrollUnit.lines;
      dx = -event.deltaX;
      dy = -event.deltaY;
    } else if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) {
      dx = -event.deltaX;
      dy = -event.deltaY;
    } else {
      dx = rect.width > 0 ? -event.deltaX / rect.width : 0;
      dy = rect.height > 0 ? -event.deltaY / rect.height : 0;
    }
    if (dx === 0 && dy === 0) return;
    this.target.send(encodeScroll(ScrollPhase.none, unit, clamp01(point.x), clamp01(point.y), dx, dy));
  };
}
