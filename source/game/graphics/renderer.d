module game.graphics.renderer;

import game.common, game.core, game.graphics, game.vulkan;

private:

// START Command/Queue related variables.
Semaphore[]                         g_renderImageAvailableSemaphores;
Semaphore[]                         g_renderRenderFinishedSemaphores;
Semaphore                           g_currentImageAvailableSemaphore;
CommandBuffer[]                     g_renderGraphicsCommandBuffers;
QueueSubmitSyncInfo[]               g_renderGraphicsSubmitSyncInfos;
DescriptorSet!TexturedQuadUniform[] g_renderDescriptorSets;
GpuCpuBuffer*[]                     g_renderDescriptorSetBuffersMandatory;
GpuCpuBuffer*[]                     g_renderDescriptorSetBuffersQuad;
uint                                g_imageIndex;

// START Rendering related variables.
MandatoryUniform g_uniformsMandatory;
DrawCommand[]    g_drawCommands;

// START Vulkan Event Callbacks
void onFrameChange(uint imageIndex)
{
    g_imageIndex = imageIndex;
}

void onSwapchainRecreate(uint imageCount)
{   
    void recreateSemaphores(ref Semaphore[] sems)
    {
        foreach(sem; sems)
            vkDestroyJAST(sem);

        sems.length = imageCount;

        foreach(ref sem; sems)
            sem = Semaphore(g_device);
    }

    foreach(buffer; g_renderGraphicsCommandBuffers)
        vkDestroyJAST(buffer);
    g_renderGraphicsCommandBuffers = g_device.graphics.commandPools.get(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT).allocate(imageCount);

    g_renderDescriptorSetBuffersMandatory.length = imageCount;
    g_renderDescriptorSetBuffersQuad.length      = imageCount;
    foreach(i; 0..imageCount)
    {
        g_renderDescriptorSetBuffersMandatory[i] = g_gpuCpuAllocator.allocate(MandatoryUniform.sizeof,    VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        g_renderDescriptorSetBuffersQuad[i]      = g_gpuCpuAllocator.allocate(TexturedQuadUniform.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    }

    recreateSemaphores(Ref(g_renderImageAvailableSemaphores));
    recreateSemaphores(Ref(g_renderRenderFinishedSemaphores));

    g_renderGraphicsSubmitSyncInfos.length = imageCount;
}

public:

// START Data Types

struct DrawCommand
{
    VertexBuffer* buffer;
    size_t        offset;
    size_t        count;
    Texture       texture;
    bool          enableBlending;
    int           sortOrder; // User-specified sort order, e.g. 0 = Background, 1 = player, etc.
    uint          drawOrder; // Submission order. So if this was the 2nd command this frame, then this'd be 2. Used to preserve a bit of command ordering.
}

void renderInit()
{
    onSwapchainRecreate(cast(uint)g_swapchain.images.length);

    vkListenOnFrameChangeJAST((v) => onFrameChange(v));
    vkListenOnSwapchainRecreateJAST((v) => onSwapchainRecreate(v));

    g_uniformsMandatory.projection = mat4f.orthographic(0, Window.size.x, 0, Window.size.y, 1, 0);
}

void renderFrameBegin()
{
    g_currentImageAvailableSemaphore = g_renderImageAvailableSemaphores[g_imageIndex];

    uint imageIndex;
    const imageFetchResult = vkAcquireNextImageKHR(
        g_device,
        g_swapchain.handle,
        ulong.max,
        g_currentImageAvailableSemaphore,
        null,
        &imageIndex
    );

    vkEmitOnFrameChangeJAST(imageIndex);
    while(g_renderGraphicsSubmitSyncInfos[imageIndex] != QueueSubmitSyncInfo.init 
      && !g_renderGraphicsSubmitSyncInfos[imageIndex].submitHasFinished
    )
    {
        g_device.graphics.processFences();
    }

    auto buffer = g_renderGraphicsCommandBuffers[g_imageIndex];
    buffer.begin(ResetOnSubmit.yes);

    if(imageFetchResult == VK_ERROR_OUT_OF_DATE_KHR || imageFetchResult == VK_SUBOPTIMAL_KHR)
    {
        renderFrameEnd(); // Clear any state that'd end up in limbo otherwise.
        vkDeviceWaitIdle(g_device);

        // If we're minimised, swapchain recreation will crash, so wait until we're maximised again.
        while(Window.isMinimised)
        {
            // (Really should do this better, but as long as it works for now, then its fine)
            import core.thread, core.time, bindbc.sdl;
            Thread.sleep(500.msecs);

            SDL_Event e;
            while(Window.nextEvent(&e)){}
        }

        Swapchain.create(g_swapchain);
        vkRecreateAllJAST();
        return;
    }
}

void renderFrameEnd()
{
    import std.format    : format;
    import bindbc.sdl    : SDL_GetTicks;
    import std.algorithm : multiSort;

    multiSort!(
        "a.sortOrder       < b.sortOrder",
        "a.enableBlending != b.enableBlending",
        "a.drawOrder       < b.drawOrder",
        "a.texture        != b.texture"
    )(g_drawCommands);

    auto buffer = g_renderGraphicsCommandBuffers[g_imageIndex];

    buffer.pushDebugRegion("Begin Render Pass");
    buffer.beginRenderPass(g_swapchain.framebuffers[g_imageIndex]);

    buffer.pushDebugRegion("Setting common data");
        buffer.pushConstants(g_pipelineQuadTexturedTransparent.base, PushConstants(SDL_GetTicks()));
    buffer.popDebugRegion();
    foreach(i, command; g_drawCommands)
    {
        assert(command.texture !is null,    "There must be a texture.");
        assert(!command.texture.isDisposed, "Texture has been disposed of.");

        // Don't care if textures aren't loaded yet, so just skip this frame.
        if(!command.texture.finalise())
            continue;

        // However, verts we *do* care about, so we'll wait for those.
        while(!command.buffer.finalise())
            g_device.transfer.processFences();

        auto pipeline = (command.enableBlending) ? g_pipelineQuadTexturedTransparent.base : g_pipelineQuadTexturedOpaque.base;
        buffer.pushDebugRegion(
            "Command %s Texture %s Blending %s Sort %s Draw %s"
            .format(i, command.texture, command.enableBlending, command.sortOrder, command.drawOrder),
            Color(38, 72, 102)
        );
            buffer.bindPipeline(pipeline);

            g_renderDescriptorSetBuffersMandatory[g_imageIndex].as!MandatoryUniform[0] = g_uniformsMandatory;

            auto uniforms = g_descriptorPools.pool.allocate!TexturedQuadUniform(pipeline);
            uniforms.update(
                command.texture.imageView, 
                command.texture.sampler,
                g_renderDescriptorSetBuffersMandatory[g_imageIndex],
                g_renderDescriptorSetBuffersQuad[g_imageIndex]
            );
            buffer.bindVertexBuffer(command.buffer.gpuHandle);
            buffer.bindDescriptorSet(pipeline, uniforms);
            buffer.drawVerts(cast(uint)command.count, cast(uint)command.offset);
        buffer.popDebugRegion();
    }

    buffer.endRenderPass();
    buffer.popDebugRegion();
    buffer.end();

    // Clear temp data
    g_drawCommands.length = 0;

    // Submit primary graphics buffer.
    auto renderFinishedSemaphore = g_renderRenderFinishedSemaphores[g_imageIndex];
    auto imageAvailableSemaphore = g_currentImageAvailableSemaphore;
    g_renderGraphicsSubmitSyncInfos[g_imageIndex] = g_device.graphics.submit(
        buffer, 
        &renderFinishedSemaphore, 
        &imageAvailableSemaphore,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT 
    );

    // Present changes to screen.
    VkPresentInfoKHR presentInfo =
    {
        waitSemaphoreCount: 1,
        swapchainCount:     1,
        pWaitSemaphores:    &renderFinishedSemaphore.handle,
        pSwapchains:        &g_swapchain.handle,
        pImageIndices:      &g_imageIndex
    };

    vkQueuePresentKHR(g_device.present.handle, &presentInfo);
}