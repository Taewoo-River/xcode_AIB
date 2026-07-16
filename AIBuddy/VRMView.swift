import SwiftUI
import WebKit

// 3D VRM character avatar — same approach as the PC version: three.js +
// @pixiv/three-vrm from the jsDelivr CDN, rendered in a WKWebView, with
// idle sway, blinking, and level-driven lip-sync.
// Needs internet on first load for the 3D libraries (like the original).

enum VRMViewer {

    static let samples: [(file: String, url: String)] = [
        ("Sample-Chan.vrm", "https://raw.githubusercontent.com/pixiv/three-vrm/dev/packages/three-vrm/examples/models/VRM1_Constraint_Twist_Sample.vrm"),
        ("VRoid-Sample-A.vrm", "https://raw.githubusercontent.com/madjin/vrm-samples/master/vroid/stable/AvatarSample_A.vrm"),
        ("VRoid-Sample-B.vrm", "https://raw.githubusercontent.com/madjin/vrm-samples/master/vroid/stable/AvatarSample_B.vrm"),
        ("VRoid-Sample-C.vrm", "https://raw.githubusercontent.com/madjin/vrm-samples/master/vroid/stable/AvatarSample_C.vrm")
    ]

    static var viewerURL: URL { Paths.avatars.appendingPathComponent("viewer.html") }

    static func installedModels() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.avatars.path)) ?? []
        return files.filter { $0.lowercased().hasSuffix(".vrm") }.sorted()
    }

    static func importModel(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".vrm") else { throw BuddyError("Only .vrm files are supported.") }
        let dest = Paths.avatars.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        try data.write(to: dest)
        return name
    }

    static func downloadSamples(status: @MainActor @escaping (String) -> Void) async -> String {
        var saved: [String] = []
        var failed: [String] = []
        for (file, urlString) in samples {
            let dest = Paths.avatars.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dest.path) {
                saved.append(file)
                continue
            }
            await status("Downloading \(file)…")
            do {
                guard let url = URL(string: urlString) else { throw BuddyError("bad URL") }
                let (data, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                    throw BuddyError("HTTP \(http.statusCode)")
                }
                try data.write(to: dest)
                saved.append(file)
            } catch {
                failed.append(file)
            }
        }
        if failed.isEmpty { return "Ready: \(saved.joined(separator: ", "))" }
        return "Got \(saved.count), failed: \(failed.joined(separator: ", ")) — check the internet connection and try again."
    }

    static func writeViewerHTML() {
        try? FileManager.default.createDirectory(at: Paths.avatars, withIntermediateDirectories: true)
        try? viewerHTML.data(using: .utf8)?.write(to: viewerURL)
    }

    static let viewerHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
      html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
      canvas { display: block; }
      #note { position: absolute; top: 10px; left: 10px; right: 10px; color: #7fd4ff;
              font: 12px -apple-system, sans-serif; opacity: 0.85; text-align: center; }
    </style>
    <script type="importmap">
    {
      "imports": {
        "three": "https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js",
        "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/",
        "@pixiv/three-vrm": "https://cdn.jsdelivr.net/npm/@pixiv/three-vrm@3.4.4/lib/three-vrm.module.min.js"
      }
    }
    </script>
    </head>
    <body>
    <div id="note">loading 3D libraries…</div>
    <script>
    // The app may call loadModel() before the ES module below has finished
    // downloading its CDN imports — queue the request until then. Also surface
    // any load error into the note so failures aren't silent.
    window.pendingModel = null;
    window.loadModel = function (f) { window.pendingModel = f; };
    window.avatarSet = function () {};
    window.addEventListener('error', function (e) {
      var n = document.getElementById('note');
      if (n) n.textContent = 'Error: ' + (e.message || 'script failed') +
        ' — 3D avatars need internet on first load for the three.js libraries.';
    });
    window.addEventListener('unhandledrejection', function (e) {
      var n = document.getElementById('note');
      if (n) n.textContent = 'Error: ' + (e.reason && e.reason.message ? e.reason.message : e.reason) +
        ' — 3D avatars need internet on first load for the three.js libraries.';
    });
    </script>
    <script type="module">
    import * as THREE from 'three';
    import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
    import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';

    const note = document.getElementById('note');
    let vrm = null;
    let state = 'idle';
    let level = 0;
    let smooth = 0;

    window.avatarSet = function (s, v) { state = s; level = v; };

    const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true });
    renderer.setSize(innerWidth, innerHeight);
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    document.body.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(30, innerWidth / innerHeight, 0.1, 20);
    camera.position.set(0, 1.35, 1.7);
    camera.lookAt(0, 1.25, 0);
    scene.add(new THREE.AmbientLight(0xffffff, 0.8));
    const dirLight = new THREE.DirectionalLight(0xffffff, 1.2);
    dirLight.position.set(1, 2, 1);
    scene.add(dirLight);

    const loader = new GLTFLoader();
    loader.register(function (parser) { return new VRMLoaderPlugin(parser); });

    window.loadModel = function (file) {
      if (!file) { note.textContent = 'No VRM character selected — pick or download one in settings.'; return; }
      note.style.display = '';
      note.textContent = 'loading character…';
      if (vrm) { scene.remove(vrm.scene); vrm = null; }
      loader.load(encodeURIComponent(file), function (gltf) {
        vrm = gltf.userData.vrm;
        VRMUtils.rotateVRM0(vrm);
        scene.add(vrm.scene);
        const la = vrm.humanoid && vrm.humanoid.getNormalizedBoneNode('leftUpperArm');
        const ra = vrm.humanoid && vrm.humanoid.getNormalizedBoneNode('rightUpperArm');
        if (la) la.rotation.z = 1.15;
        if (ra) ra.rotation.z = -1.15;
        note.style.display = 'none';
      }, undefined, function (err) {
        note.textContent = 'Could not load the 3D character: ' + (err && err.message ? err.message : err) +
          ' — 3D avatars need internet on first load for the three.js libraries.';
      });
    };

    // Replay a loadModel() request that arrived before this module finished loading.
    if (window.pendingModel) {
      const pending = window.pendingModel;
      window.pendingModel = null;
      window.loadModel(pending);
    }

    const clock = new THREE.Clock();
    let blinkT = 2 + Math.random() * 3;
    let blinkPhase = 0;

    function tick() {
      requestAnimationFrame(tick);
      const dt = clock.getDelta();
      const t = clock.elapsedTime;
      const target = state === 'speaking'
        ? Math.max(level, 0.25) * (0.55 + 0.45 * Math.sin(t * 13) * Math.sin(t * 7.3))
        : 0;
      smooth += (target - smooth) * 0.3;
      if (vrm) {
        const h = vrm.humanoid;
        const chest = h && (h.getNormalizedBoneNode('chest') || h.getNormalizedBoneNode('spine'));
        if (chest) chest.rotation.x = Math.sin(t * 1.4) * 0.02;
        const head = h && h.getNormalizedBoneNode('head');
        if (head) {
          head.rotation.y = Math.sin(t * 0.6) * 0.06 + (state === 'listening' ? 0.05 : 0);
          head.rotation.z = Math.sin(t * 0.83) * 0.03;
          head.rotation.x = state === 'thinking' ? -0.06 : 0;
        }
        blinkT -= dt;
        if (blinkT <= 0) { blinkPhase = 0.0001; blinkT = 2 + Math.random() * 3.5; }
        if (blinkPhase > 0 && vrm.expressionManager) {
          blinkPhase += dt;
          const v = Math.sin(Math.min(blinkPhase / 0.15, 1) * Math.PI);
          vrm.expressionManager.setValue('blink', v);
          if (blinkPhase > 0.15) { blinkPhase = 0; vrm.expressionManager.setValue('blink', 0); }
        }
        if (vrm.expressionManager) {
          vrm.expressionManager.setValue('aa', Math.max(0, Math.min(1, smooth)));
        }
        vrm.update(dt);
      }
      renderer.render(scene, camera);
    }
    tick();

    addEventListener('resize', function () {
      renderer.setSize(innerWidth, innerHeight);
      camera.aspect = innerWidth / innerHeight;
      camera.updateProjectionMatrix();
    });
    </script>
    </body>
    </html>
    """
}

// ------------------------------------------------------------------ SwiftUI wrapper

struct VRMAvatarView: UIViewRepresentable {
    let modelFile: String
    let state: String
    let level: Double

    final class Coordinator: NSObject, WKNavigationDelegate {
        var modelFile = ""
        var loaded = false
        var lastPushed = ""

        static func escapeJS(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            webView.evaluateJavaScript("loadModel('\(Self.escapeJS(modelFile))');", completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // allow the viewer page (a local file) to fetch .vrm files beside it
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = context.coordinator
        context.coordinator.modelFile = modelFile

        VRMViewer.writeViewerHTML()
        web.loadFileURL(VRMViewer.viewerURL, allowingReadAccessTo: Paths.avatars)
        return web
    }

    // SwiftUI re-renders whenever state/level change, so pushing from here
    // keeps the character in sync without any polling timer.
    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.modelFile != modelFile {
            context.coordinator.modelFile = modelFile
            if context.coordinator.loaded {
                web.evaluateJavaScript("loadModel('\(Coordinator.escapeJS(modelFile))');", completionHandler: nil)
            }
        }
        guard context.coordinator.loaded else { return }
        let js = "window.avatarSet && window.avatarSet('\(Coordinator.escapeJS(state))', \(String(format: "%.3f", level)));"
        if js != context.coordinator.lastPushed {
            context.coordinator.lastPushed = js
            web.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
