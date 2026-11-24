import React from 'react';
import ttplayIconUrl from '../assets/ttplay-icon.png';

interface BrandLogoProps {
  size?: number;
  alt?: string;
}

export const BrandLogo: React.FC<BrandLogoProps> = ({ size = 32, alt = 'TTPlay' }) => {
  const radius = size >= 40 ? 12 : 10;
  return (
    <span
      className="brand-mark brand-mark-logo"
      style={{ width: size, height: size, borderRadius: radius }}
    >
      <img src={ttplayIconUrl} alt={alt} width={size} height={size} draggable={false} />
    </span>
  );
};
