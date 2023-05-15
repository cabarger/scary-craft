
#version 330

// Input vertex attributes (from vertex shader)
in vec3 fragPosition;
in vec2 fragTexCoord;
in vec3 fragNormal;

// Input uniform values
uniform sampler2D texture0;

// Output fragment color
out vec4 finalColor;

struct Light {
    int enabled;
    int type;
    vec3 position;
    vec3 target;
    vec4 color;
};

// Input lighting values
uniform vec4 ambient;
uniform vec3 viewPos;
uniform Light light;

void main()
{
    // Texel color fetching from texture sampler
    vec4 texelColor = texture(texture0, fragTexCoord);
    vec3 normal = normalize(fragNormal); // Why norm twice? TODO(caleb): test without normalize call.
    //vec3 viewD = normalize(viewPos - fragPosition);
    vec3 viewD = normalize(light.position - fragPosition);
    
    float diffuse = max(dot(normal, viewD), 0.0);
            
	finalColor = (ambient + diffuse) * light.color * texelColor;
}