import { Camera } from "./camera";
import { Lights } from "./lights";
import { Scene } from "./scene";

export class Stage {
    scene: Scene;
    lights: Lights;
    camera: Camera;
    stats: Stats;

    constructor(scene: Scene, lights: Lights, camera: Camera, stats: Stats) {
        this.scene = scene;
        this.lights = lights;
        this.camera = camera;
        this.stats = stats;
    }
}
