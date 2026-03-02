'use client';

import { motion, useScroll, useTransform } from 'framer-motion';
import { useRef } from 'react';

export function HeroLogo() {
    const containerRef = useRef(null);
    const { scrollYProgress } = useScroll({
        target: containerRef,
        offset: ["start start", "end start"]
    });

    const y = useTransform(scrollYProgress, [0, 1], ["0%", "20%"]);
    const opacity = useTransform(scrollYProgress, [0, 0.5], [0.15, 0]);

    return (
        <div ref={containerRef} className="absolute inset-0 flex items-center justify-center overflow-hidden pointer-events-none z-0">
            {/* The Halftone "F" Logo */}
            <motion.div
                style={{ y, opacity }}
                className="relative w-[120vw] md:w-[80vw] aspect-square flex items-center justify-center"
            >
                {/* Provided "F" Path as a masking container */}
                <div
                    className="absolute inset-0 bg-current mask-f-logo"
                    style={{
                        maskImage: `url("data:image/svg+xml,%3Csvg width='128' height='22' viewBox='0 0 128 22' fill='none' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath d='M12.0021 5.50286H20.9807C21.5362 5.50286 21.9885 5.05622 21.9885 4.50078V1.00208C21.9885 0.446642 21.5362 0 20.9807 0H6.50494C5.9495 0 5.49714 0.446642 5.49714 1.00208V4.50078C5.49714 5.05622 5.04477 5.50286 4.48933 5.50286H1.00781C0.452368 5.50286 0 5.94951 0 6.50495V20.9979C0 21.5534 0.452368 22 1.00781 22H4.4836C5.03904 22 5.49141 21.5534 5.49141 20.9979V12.0021C5.49141 11.4466 5.94378 11 6.49922 11H9.98074C10.5305 11 10.9885 11.4466 10.9885 12.0021V20.9979C10.9885 21.5534 11.4466 22 11.9964 22H15.4779C16.0333 22 16.4857 21.5534 16.4857 20.9979V17.5049C16.4857 16.9839 16.8808 16.5544 17.379 16.4971H20.975C21.5247 16.4971 21.9828 16.0505 21.9828 15.4951V11.9964C21.9828 11.4409 21.5305 10.9943 20.975 10.9943H11.9906C11.4352 10.9943 10.9828 10.5476 10.9828 9.99219V6.49922C10.9828 5.94378 11.4352 5.49714 11.9906 5.49714L12.0021 5.50286Z' fill='white'/%3E%3C/svg%3E")`,
                        maskSize: 'contain',
                        maskRepeat: 'no-repeat',
                        maskPosition: 'center',
                        WebkitMaskImage: `url("data:image/svg+xml,%3Csvg width='128' height='22' viewBox='0 0 128 22' fill='none' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath d='M12.0021 5.50286H20.9807C21.5362 5.50286 21.9885 5.05622 21.9885 4.50078V1.00208C21.9885 0.446642 21.5362 0 20.9807 0H6.50494C5.9495 0 5.49714 0.446642 5.49714 1.00208V4.50078C5.49714 5.05622 5.04477 5.50286 4.48933 5.50286H1.00781C0.452368 5.50286 0 5.94951 0 6.50495V20.9979C0 21.5534 0.452368 22 1.00781 22H4.4836C5.03904 22 5.49141 21.5534 5.49141 20.9979V12.0021C5.49141 11.4466 5.94378 11 6.49922 11H9.98074C10.5305 11 10.9885 11.4466 10.9885 12.0021V20.9979C10.9885 21.5534 11.4466 22 11.9964 22H15.4779C16.0333 22 16.4857 21.5534 16.4857 20.9979V17.5049C16.4857 16.9839 16.8808 16.5544 17.379 16.4971H20.975C21.5247 16.4971 21.9828 16.0505 21.9828 15.4951V11.9964C21.9828 11.4409 21.5305 10.9943 20.975 10.9943H11.9906C11.4352 10.9943 10.9828 10.5476 10.9828 9.99219V6.49922C10.9828 5.94378 11.4352 5.49714 11.9906 5.49714L12.0021 5.50286Z' fill='white'/%3E%3C/svg%3E")`,
                        WebkitMaskSize: 'contain',
                        WebkitMaskRepeat: 'no-repeat',
                        WebkitMaskPosition: 'center',
                    }}
                >
                    {/* The Dithered/Raster Pattern Layer */}
                    <div className="absolute inset-0 bg-current dither-pattern" />
                </div>

                {/* Subtle Glow Overlay */}
                <div className="absolute inset-0 bg-white dark:bg-black opacity-[0.02] filter blur-[120px]" />
            </motion.div>

            {/* CSS Variables for the Dither Effect */}
            <style jsx>{`
                .dither-pattern {
                    background-image: 
                        radial-gradient(circle at center, var(--fao-fg) 1px, transparent 1px),
                        linear-gradient(to right, var(--fao-fg) 1px, transparent 1px),
                        linear-gradient(to bottom, var(--fao-fg) 1px, transparent 1px);
                    background-size: 4px 4px, 12px 12px, 12px 12px;
                    background-position: 0 0, 0 0, 0 0;
                    opacity: 0.12;
                    mix-blend-mode: overlay;
                }
                .mask-f-logo {
                    background-color: var(--fao-fg);
                }
                :global(.dark) .dither-pattern {
                    opacity: 0.08;
                    mix-blend-mode: screen;
                }
            `}</style>
        </div>
    );
}
