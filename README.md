# SpriteKit Motion Blur

This project implements per-sprite motion blur with SpriteKit and GLSL fragment shaders.

## Video

https://github.com/user-attachments/assets/8d2ff523-547e-41e8-aea6-716caa53d7b8

## Run The Demo

This implementation is dependency-free. Download, build, and run. Or copy/paste SpriteMotionBlur.swift in your own project.

## How It Works

This scene implements per-sprite motion blur with a fragment shader. The sprite is larger than the visible shape, so the shader has transparent drawing room around the circle.
Each fragment samples the sprite texture several times along the current movement direction, then averages those samples into one final color. The scene updates the blur direction and length from the sprite physics velocity.
The sprite is moved with a Proportional-Derivative (PD) physics-based controller.

## Findings

- The motion blur effect works provided the sprite velocity changes continuously.
- If the velocity direction changes suddenly, such as after a collision, the visual effect breaks.
- Performance depends on the GPU and sample count in the shader.

## Credits

This is a pure SpriteKit, dependency-free version of this experiment:
https://github.com/alexwidua/zoom-motion-blur
