/**
 
 # Sprite Motion Blur
 
 This scene implements per-sprite motion blur with a fragment shader.
 The sprite is larger than the visible shape, so the shader has transparent drawing room around the circle.
 
 Each fragment samples the sprite texture several times along the current movement direction, then averages those samples into one final color.
 The scene updates the blur direction and length from the sprite physics velocity.
 
 The sprite is moved with a Proportional-Derivative (PD) physics-based controller.
 
 ## Findings
 
 - The motion blur effect works only if the sprite velocity changes continuously.
 - If the sprite collides, the velocity direction would suddenly change, and the effect would break.
 - Performance depends on the GPU and sample count in the shader.
 
 ## Side Experiment
 
 This file also compares two strategies:
 - A padded texture path.
 - A remapped texture path.
 
 The padded path generates one large texture with the circle already centered inside transparent padding.
 The remapped path generates only the circle texture, then the shader remaps it into the center of the larger sprite.
 
 The version with the already padded texture is significantly faster.
 
 ## Links
 
 This is a pure SpriteKit, dependency-free version of this experiment:
 https://github.com/alexwidua/zoom-motion-blur
 
 Achraf Kassioui
 Created 19 Jun 2026
 Updated 20 Jun 2026
 
 */
import SwiftUI
import SpriteKit

// MARK: View

struct SpriteMotionBlurView: View {
    @State var scene = SpriteMotionBlurScene()
    
    var body: some View {
        ZStack {
            SpriteView(
                scene: scene,
                preferredFramesPerSecond: 120,
                options: [.ignoresSiblingOrder],
                debugOptions: [.showsFPS, .showsNodeCount, .showsDrawCount]
            )
            .ignoresSafeArea()
            
            VStack {
                Spacer()
                
                HStack {
                    HorizontalSlider(
                        value: $scene.blurAmount,
                        range: 0...60,
                        steps: 1,
                        label: "Blur",
                        color: .yellow
                    )
                }
                .frame(maxWidth: 640)
            }
            .padding()
        }
    }
    
    /**
     
     Custom slider because the native SwiftUI slider crashes on macOS when value reaches the edges.
     
     */
    private struct HorizontalSlider: View {
        @Binding var value: Float
        var range: ClosedRange<Float>
        var steps: Float
        var label: String
        var color: Color = .blue
        
        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text(label)
                        .foregroundColor(.white.opacity(0.35))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    
                    Spacer()
                    
                    Text("\(value, specifier: "%.0f")")
                        .foregroundColor(.white)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
                .padding([.top, .leading, .trailing], 20)
                
                GeometryReader { geometry in
                    let normalizedValue = normalizedValue()
                    let trackWidth = geometry.size.width
                    let handleSize: CGFloat = 44
                    let handleX = CGFloat(normalizedValue) * trackWidth
                    
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.18))
                            .frame(height: 6)
                        
                        Capsule()
                            .fill(color)
                            .frame(width: max(handleX, 0), height: 6)
                        
                        Circle()
                            .fill(.white)
                            .frame(width: handleSize, height: handleSize)
                            .shadow(radius: 4, y: 2)
                            .offset(x: min(max(handleX - handleSize * 0.5, 0), trackWidth - handleSize))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                updateValue(
                                    from: drag.location.x,
                                    trackWidth: trackWidth
                                )
                            }
                    )
                }
                .frame(height: 44)
                .padding(20)
            }
            .background(RoundedRectangle(cornerRadius: 24.0).fill(.gray.opacity(0.15)))
        }
        
        private func normalizedValue() -> Float {
            let rangeLength = range.upperBound - range.lowerBound
            guard rangeLength > 0 else { return 0 }
            
            return (value - range.lowerBound) / rangeLength
        }
        
        private func updateValue(from locationX: CGFloat, trackWidth: CGFloat) {
            guard trackWidth > 0 else { return }
            
            /// Clamp before converting so dragging beyond the slider edges cannot produce invalid values.
            let clampedX = min(max(locationX, 0), trackWidth)
            let normalizedLocation = Float(clampedX / trackWidth)
            let rawValue = range.lowerBound + normalizedLocation * (range.upperBound - range.lowerBound)
            
            /// Snap to step values.
            let steppedValue = (rawValue / steps).rounded() * steps
            
            value = min(max(steppedValue, range.lowerBound), range.upperBound)
        }
    }
}

#Preview {
    SpriteMotionBlurView()
}

// MARK: Scene

@Observable
class SpriteMotionBlurScene: SKScene {
    
    // MARK: Properties
    
    private let sprite = SKSpriteNode()
    private let spriteSize = CGSize(width: 600, height: 600)
    private let shapeSize = CGSize(width: 100, height: 100)
    
    /// Drag state.
    private var lastUpdateTime: TimeInterval = 0
    private var activeTouch: UITouch?
    private var touchOffset = CGPoint.zero
    private var targetPosition = CGPoint.zero
    
    /// Controller tuning during drag.
    private let dragStiffness: CGFloat = 280
    private let dragDamping: CGFloat = 24
    
    /// Controller tuning after release.
    private let returnStiffness: CGFloat = 60
    private let returnDamping: CGFloat = 10
    
    /// Updated by SwiftUI with @Observable
    var blurAmount: Float = 40
    
    /// Toggle the texture setup used by the experiment.
    /// true = large generated texture with built-in padding.
    /// false = small generated texture remapped by the shader.
    private let usesPaddedTexture = true
    
    /// Speed in points/second that produces the maximum blur.
    private let speedForMaximumBlur: CGFloat = 1500
    
    /// Motion blur direction in the sprite UV space.
    private let blurDirectionUniform = SKUniform(
        name: "u_blur_direction",
        vectorFloat2: vector_float2(1, 0)
    )
    
    /// Motion blur length in the sprite UV space.
    private let blurStrengthUniform = SKUniform(
        name: "u_blur_strength",
        float: 0
    )
    
    // MARK: Lifecycle
    
    override func didMove(to view: SKView) {
        scaleMode = .resizeFill
        size = view.bounds.size
        backgroundColor = .black
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        view.isMultipleTouchEnabled = true
        view.contentMode = .center
        physicsWorld.gravity = .zero
        
        cleanup()
        
        createContent(view: view)
        
        if usesPaddedTexture {
            createShader()
        } else {
            createShaderWithRemap()
        }
    }
    
    override func willMove(from view: SKView) {
        cleanup()
    }
    
    deinit {
        cleanup()
    }
    
    private func cleanup() {
        removeAllChildren()
    }
    
    // MARK: Content
    
    private func createContent(view: SKView) {
        let label = SKLabelNode(text: "Sprite Motion Blur")
        label.fontName = "Menlo-Bold"
        label.fontSize = 20
        label.fontColor = .black
        label.position = CGPoint(x: 0, y: 300)
        label.zPosition = 20
        addChild(label)
        
        /// Sprite.
        if usesPaddedTexture {
            sprite.texture = generatePaddedTexture(view: view)
        } else {
            sprite.texture = generateTexture(view: view)
        }
        sprite.size = spriteSize
        
        /// Physics matches the visible circle, not the padded texture.
        sprite.physicsBody = SKPhysicsBody(circleOfRadius: shapeSize.width / 2)
        sprite.zPosition = 10
        addChild(sprite)
    }
    
    private func generatePaddedTexture(view: SKView) -> SKTexture? {
        /**
         
         Generate a padded texture.
         
         The container is the full shader draw area.
         The circle is the visible content.
         
         */
        let textureContainer = SKNode()
        
        /// Transparent canvas that defines the final texture size.
        let canvas = SKSpriteNode(color: .clear, size: spriteSize)
        textureContainer.addChild(canvas)
        
        /// Visible shape centered inside the padded texture.
        let circle = SKShapeNode(circleOfRadius: shapeSize.width / 2)
        circle.lineWidth = 0
        circle.fillColor = .white
        circle.position = .zero
        textureContainer.addChild(circle)
        
        return view.texture(from: textureContainer)
    }
    
    private func generateTexture(view: SKView) -> SKTexture? {
        /**
         
         Generate only the visible circle texture.
         
         */
        let circle = SKShapeNode(circleOfRadius: shapeSize.width / 2)
        circle.lineWidth = 0
        circle.fillColor = .white
        
        return view.texture(from: circle)
    }
    
    // MARK: Shader
    
    private func createShader() {
        let shader = SKShader(source:
"""
void main() {
    /// UV position across the texture.
    vec2 uv = v_tex_coord;
    
    /// Direction and length of the blur in texture UV space.
    vec2 blurDirection = normalize(u_blur_direction + vec2(0.0001));
    float blurStrength = u_blur_strength;
    
    /*
     
     Motion blur.
     
     The shader samples the texture several times along one line.
     The line is centered on the current fragment and follows the movement direction.
     
     The texture already includes transparent padding, so blur samples have room to extend without being clipped by the sprite bounds.

     Change sampleCount for higher/lower quality/performance.
     
     */
    const int sampleCount = 30;
    
    vec4 accumulatedColor = vec4(0.0);
    float accumulatedWeight = 0.0;
    
    for (int sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
        /// Convert sample index into a centered range: -1...1.
        float normalizedSampleIndex = float(sampleIndex) / float(sampleCount - 1);
        float centeredSampleOffset = normalizedSampleIndex * 2.0 - 1.0;
        
        vec2 sampleUV = uv + blurDirection * blurStrength * centeredSampleOffset;
        sampleUV = clamp(sampleUV, vec2(0.0), vec2(1.0));
        
        accumulatedColor += texture2D(u_texture, sampleUV);
        accumulatedWeight += 1.0;
    }
    
    /// Average the samples to keep the texture brightness stable.
    gl_FragColor = accumulatedColor / accumulatedWeight;
}
"""
        )
        
        shader.uniforms = [
            blurDirectionUniform,
            blurStrengthUniform,
        ]
        
        sprite.shader = shader
    }
    
    private func createShaderWithRemap() {
        let shader = SKShader(source:
"""
void main() {
    /// UV position across the full sprite size.
    vec2 uv = v_tex_coord;
    
    /// The smaller texture is drawn into the center of the full sprite.
    vec2 textureAreaSize = u_texture_size / u_draw_area_size;
    vec2 textureAreaStart = (vec2(1.0) - textureAreaSize) * 0.5;
    
    /// Direction and length of the blur in full UV space.
    vec2 blurDirection = normalize(u_blur_direction + vec2(0.0001));
    float blurStrength = u_blur_strength;
    
    /*
     
     Motion blur with texture remapping.
     
     The sprite is the full draw area.
     The texture is the smaller visible circle.
     
     */
    const int sampleCount = 30;
    
    vec4 accumulatedColor = vec4(0.0);
    float accumulatedWeight = 0.0;
    
    for (int sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
        /// Convert sample index into a centered range: -1...1.
        float normalizedSampleIndex = float(sampleIndex) / float(sampleCount - 1);
        float centeredSampleOffset = normalizedSampleIndex * 2.0 - 1.0;
        
        /// Sample position inside the full sprite.
        vec2 sampleUV = uv + blurDirection * blurStrength * centeredSampleOffset;
        
        /// Convert full-sprite UV into smaller-texture UV.
        vec2 textureUV = (sampleUV - textureAreaStart) / textureAreaSize;
        
        bool isInsideTextureArea =
        textureUV.x >= 0.0 &&
        textureUV.x <= 1.0 &&
        textureUV.y >= 0.0 &&
        textureUV.y <= 1.0;
        
        vec4 sampleColor = vec4(0.0);
        
        if (isInsideTextureArea) {
            sampleColor = texture2D(u_texture, textureUV);
        }
        
        accumulatedColor += sampleColor;
        accumulatedWeight += 1.0;
    }
    
    /// Average the samples to maintain the texture brightness.
    gl_FragColor = accumulatedColor / accumulatedWeight;
}
"""
        )
        
        shader.uniforms = [
            SKUniform(name: "u_draw_area_size", vectorFloat2: vector_float2(Float(spriteSize.width), Float(spriteSize.height))),
            SKUniform(name: "u_texture_size", vectorFloat2: vector_float2(Float(shapeSize.width), Float(shapeSize.height))),
            blurDirectionUniform,
            blurStrengthUniform,
        ]
        
        sprite.shader = shader
    }
    
    private func updateShader(body: SKPhysicsBody) {
        let speed = hypot(body.velocity.dx, body.velocity.dy)
        
        if speed > 1 {
            blurDirectionUniform.vectorFloat2Value = vector_float2(
                Float(body.velocity.dx / speed),
                Float(body.velocity.dy / speed)
            )
        }
        
        /// blurAmount is in points.
        /// The shader needs UV distance across the sprite draw area.
        let speedRatio = min(speed / speedForMaximumBlur, 1)
        let blurLengthInPoints = CGFloat(blurAmount) * speedRatio
        let blurLengthInUV = blurLengthInPoints / sprite.size.width
        
        blurStrengthUniform.floatValue = Float(blurLengthInUV)
    }
    
    // MARK: Update
    
    override func update(_ currentTime: TimeInterval) {
        guard let body = sprite.physicsBody else { return }
        
        if lastUpdateTime == 0 {
            lastUpdateTime = currentTime
            return
        }
        
        let deltaTime = currentTime - lastUpdateTime
        lastUpdateTime = currentTime
        
        updateController(body: body, deltaTime: deltaTime)
        updateShader(body: body)
    }
    
    private func updateController(body: SKPhysicsBody, deltaTime: TimeInterval) {
        /**
         
         Basic PD controller.
         
         Position error says where the sprite wants to go.
         Velocity damping removes wobble.
         The result is written as velocity.
         
         */
        let positionError = CGPoint(
            x: targetPosition.x - sprite.position.x,
            y: targetPosition.y - sprite.position.y
        )
        
        let currentStiffness = activeTouch == nil ? returnStiffness : dragStiffness
        let currentDamping = activeTouch == nil ? returnDamping : dragDamping
        
        let acceleration = CGVector(
            dx: positionError.x * currentStiffness - body.velocity.dx * currentDamping,
            dy: positionError.y * currentStiffness - body.velocity.dy * currentDamping
        )
        
        body.velocity = CGVector(
            dx: body.velocity.dx + acceleration.dx * deltaTime,
            dy: body.velocity.dy + acceleration.dy * deltaTime
        )
    }
    
    // MARK: Touch
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil,
              let touch = touches.first
        else { return }
        
        let location = touch.location(in: self)
        
        /// Hit detection with physics, so the large sprite canvas is ignored.
        guard physicsWorld.body(at: location) === sprite.physicsBody else {
            return
        }
        
        activeTouch = touch
        touchOffset = CGPoint(
            x: location.x - sprite.position.x,
            y: location.y - sprite.position.y
        )
        
        targetPosition = sprite.position
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch,
              touches.contains(activeTouch)
        else { return }
        
        let location = activeTouch.location(in: self)
        
        targetPosition = CGPoint(
            x: location.x - touchOffset.x,
            y: location.y - touchOffset.y
        )
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch,
              touches.contains(activeTouch)
        else { return }
        
        self.activeTouch = nil
        
        /// Released sprite returns to origin.
        targetPosition = .zero
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
    
}
