module game.vulkan.pipeline;

import std.conv : to;
import std.experimental.logger;
import game.common.util, game.vulkan, game.graphics.window, game.common.maths;

struct MandatoryUniform
{
    mat4f view;
    mat4f projection;
}

struct PipelineBase
{
    mixin VkSwapchainResourceWrapperJAST!VkPipeline;
    VkPipelineLayout       layoutHandle;
    VkDescriptorSetLayout  descriptorLayoutHandle;
}

struct Pipeline(VertexT, PushConstantsT, UniformT_)
{
    alias UniformT = UniformT_;

    PipelineBase* base;
    alias base this;

    static typeof(this)* wrap(PipelineBase* base)
    {
        return new typeof(this)(base);
    }

    static void create(
        scope ref   PipelineBase*                       ptr,
                    VkVertexInputBindingDescription     vertexBinding,
                    VkVertexInputAttributeDescription[] vertexAttributes,
                    Shader!(PushConstantsT, UniformT)   shader,
                    bool                                enableAlphaBlending
    )
    {
        const areWeRecreating = ptr !is null;
        if(!areWeRecreating)
            ptr = new PipelineBase();
        infof("%s a %s.", (areWeRecreating) ? "Recreating" : "Creating", typeof(this).stringof);

        if(areWeRecreating)
        {
            vkDestroyJAST(ptr);
            vkDestroyJAST(wrapperOf!VkPipelineLayout(ptr.layoutHandle));
            vkDestroyJAST(wrapperOf!VkDescriptorSetLayout(ptr.descriptorLayoutHandle));
        }

        ptr.recreateFunc = (p) => create(p, vertexBinding, vertexAttributes, shader, enableAlphaBlending);

        // ALL Vulkan structs we're populating.
        VkPipelineVertexInputStateCreateInfo    vertInputState;
        VkPipelineViewportStateCreateInfo       viewport;
        VkPipelineMultisampleStateCreateInfo    multisampling;
        VkPipelineColorBlendAttachmentState     colourBlending;
        VkPipelineColorBlendStateCreateInfo     blendState;
        VkPipelineRasterizationStateCreateInfo  rasterMouse;
        VkPipelineInputAssemblyStateCreateInfo  inputAssembly;
        VkPushConstantRange                     pushConstants;
        VkDescriptorSetLayoutBinding            mandatoryUniformBinding;
        VkDescriptorSetLayoutBinding            userDefinedUniformBinding;
        VkDescriptorSetLayoutBinding            textureSamplerBinding;
        VkDescriptorSetLayoutCreateInfo         uniformLayout;
        VkPipelineLayoutCreateInfo              layout;
        VkGraphicsPipelineCreateInfo            pipeline;

        info("Defining vertex state."); 
        with(vertInputState)
        {
            vertexBindingDescriptionCount   = 1;
            vertexAttributeDescriptionCount = vertexAttributes.length.to!uint;
            pVertexBindingDescriptions      = &vertexBinding;
            pVertexAttributeDescriptions    = vertexAttributes.ptr;
        }

        info("Defining viewport and scissor rect.");
        VkRect2D scissor;
        scissor.offset = VkOffset2D(0, 0);
        scissor.extent = Window.size.toExtent;

        VkViewport view;
        view.x        = 0;
        view.y        = 0;
        view.width    = Window.size.x;
        view.height   = Window.size.y;
        view.minDepth = 0.0f;
        view.maxDepth = 1.0f;
    
        with(viewport)
        {
            viewport.viewportCount = 1;
            viewport.scissorCount  = 1;
            viewport.pViewports    = &view;
            viewport.pScissors     = &scissor;
        }

        infof("Scissor:  %s", scissor);
        infof("Viewport: %s", view);

        info("Defining blending state.");
        with(multisampling)
        {
            sampleShadingEnable  = VK_FALSE;
            rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        }
        with(colourBlending)
        {
            colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
            if(enableAlphaBlending)
            {
                srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
                dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
                colorBlendOp        = VK_BLEND_OP_ADD;
                srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
                dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
                alphaBlendOp        = VK_BLEND_OP_ADD;
                blendEnable         = VK_TRUE;
            }
            else
                blendEnable = VK_FALSE;
        }
        with(blendState)
        {
            logicOpEnable   = VK_FALSE;
            attachmentCount = 1;
            pAttachments    = &colourBlending;
        }

        info("Defining input assembly and rasterization options.");
        with(rasterMouse)
        {
            depthClampEnable        = VK_FALSE;
            rasterizerDiscardEnable = VK_FALSE;
            polygonMode             = VK_POLYGON_MODE_FILL;
            lineWidth               = 1.0f;
            cullMode                = VK_CULL_MODE_BACK_BIT;
            frontFace               = VK_FRONT_FACE_CLOCKWISE;
            depthBiasEnable         = VK_FALSE;
            depthBiasClamp          = 0.0f;
        }
        with(inputAssembly)
        {
            primitiveRestartEnable = VK_FALSE;
            topology               = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        }

        info("Creating Pipeline Layout.");
        with(pushConstants)
        {
            stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
            size       = PushConstantsT.sizeof.to!uint;
        }
        with(textureSamplerBinding)
        {
            binding         = 0;
            descriptorCount = 1;
            descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT;
        }
        with(mandatoryUniformBinding)
        {
            binding         = 1;
            descriptorCount = 1;
            descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            stageFlags      = VK_SHADER_STAGE_VERTEX_BIT;
        }
        with(userDefinedUniformBinding)
        {
            binding         = 2;
            descriptorCount = 1;
            descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            stageFlags      = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
        }

        auto bindings = [textureSamplerBinding, mandatoryUniformBinding, userDefinedUniformBinding];
        with(uniformLayout)
        {
            bindingCount = bindings.length.to!uint();
            pBindings    = bindings.ptr;
        }

        CHECK_VK(vkCreateDescriptorSetLayout(g_device, &uniformLayout, null, &ptr.descriptorLayoutHandle));
        vkTrackJAST(wrapperOf!VkDescriptorSetLayout(ptr.descriptorLayoutHandle));

        with(layout)
        {
            pushConstantRangeCount = 1;
            setLayoutCount         = 1;
            pPushConstantRanges    = &pushConstants;
            pSetLayouts            = &ptr.descriptorLayoutHandle;
        }

        CHECK_VK(vkCreatePipelineLayout(g_device, &layout, null, &ptr.layoutHandle));
        vkTrackJAST(wrapperOf!VkPipelineLayout(ptr.layoutHandle));

        info("Creating pipeline.");
        auto shaderStages = [shader.vertex.pipelineStage, shader.fragment.pipelineStage];
        with(pipeline)
        {
            pipeline.layout     = ptr.layoutHandle;
            pipeline.renderPass = g_renderPass;
            subpass             = RenderPass.COLOUR_TO_PRESENT_SUBPASS_INDEX;
            stageCount          = shaderStages.length.to!uint;
            pStages             = shaderStages.ptr; // TODO:
            pVertexInputState   = &vertInputState;
            pInputAssemblyState = &inputAssembly;
            pViewportState      = &viewport;
            pRasterizationState = &rasterMouse;
            pMultisampleState   = &multisampling;
            pColorBlendState    = &blendState;
        }

        CHECK_VK(vkCreateGraphicsPipelines(g_device, g_pipelineCache, 1, &pipeline, null, &ptr.handle));
        vkTrackJAST(ptr);
    }
}

struct PipelineBuilder(VertexT, PushConstantsT, UniformT)
{
    static assert(__traits(hasMember, VertexT, "defineAttributes"), "Vertex type "~VertexT.stringof~" must have a function called `defineAttributes`");

    alias ShaderT = Shader!(PushConstantsT, UniformT);

    VkVertexInputAttributeDescription[] vertexAttributes;
    VkVertexInputBindingDescription     vertexBinding;
    ShaderT                             shader;
    bool                                alphaBlending;

    PipelineBuilder initialSetup()
    {
        info("Initial Setup.");

        infof("Allowing Vertex Type %s to define its attributes.", VertexT.stringof);
        VertexAttributeBuilder vertexAttributeBuilder;
        VertexT.defineAttributes(Ref(vertexAttributeBuilder));
        this.vertexAttributes = vertexAttributeBuilder.build();

        info("Defining Vertex binding.");
        this.vertexBinding.binding   = 0;
        this.vertexBinding.stride    = VertexT.sizeof;
        this.vertexBinding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        infof("Binding: %s", this.vertexBinding);

        return this;
    }

    PipelineBuilder usesShader(ShaderT shader)
    {
        this.shader = shader;
        return this;
    }

    PipelineBuilder usesAlphaBlending(bool value = true)
    {
        this.alphaBlending = value;
        return this;
    }

    Pipeline!(VertexT, PushConstantsT, UniformT)* build()
    {
        PipelineBase* ptr = null;
        typeof(return).create(
            ptr,
            this.vertexBinding,
            this.vertexAttributes,
            this.shader,
            this.alphaBlending
        );
        
        return typeof(return).wrap(ptr);
    }
}

struct VertexAttributeBuilder
{
    private VkVertexInputAttributeDescription[] _attributes;

    VkVertexInputAttributeDescription[] build()
    {
        return this._attributes;
    }

    InputBuilder location(uint loc) return
    {
        infof("\t[Start location %s]", loc);
        // InputBuilder must never outlive this struct in order for this to be safe.
        return InputBuilder(&this, loc);
    }

    static struct InputBuilder
    {
        private VertexAttributeBuilder*           _builder;
        private VkVertexInputAttributeDescription _info;

        this(VertexAttributeBuilder* builder, uint location)
        {
            this._builder       = builder;
            this._info.binding  = 0;
            this._info.location = location;
        }

        InputBuilder format(VkFormat format_)
        {
            infof("\t\tFormat: %s", format_);
            this._info.format = format_;
            return this;
        }
        
        InputBuilder offset(uint offset_)
        {
            infof("\t\tOffset: %s", offset_);
            this._info.offset = offset_;
            return this;
        }

        VertexAttributeBuilder build()
        {
            info("\t\t[End]");
            this._builder._attributes ~= this._info;
            return *this._builder;
        }
    }
}