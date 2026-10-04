import { webLightTheme, webDarkTheme, Theme } from "@fluentui/react-components";
export const gatewayTheme: Theme = {
  ...webLightTheme,
  fontFamilyBase: '"Segoe UI Variable", "Segoe UI", system-ui, sans-serif',
  colorBrandBackground: '#2463eb', colorBrandBackgroundHover: '#1d50c6', colorBrandBackgroundPressed: '#1943a3',
  colorBrandForeground1: '#2458c5', colorBrandForeground2: '#2458c5', colorBrandStroke1: '#2463eb',
  colorNeutralForeground1: '#172940', colorNeutralForeground2: '#53667d', colorNeutralForeground3: '#65768b',
  colorNeutralBackground2: '#f4f7fb', colorNeutralStroke2: '#e3e9f1',
  borderRadiusMedium: '8px', borderRadiusLarge: '12px', borderRadiusXLarge: '16px',
};

export const gatewayDarkTheme: Theme = {
  ...webDarkTheme,
  fontFamilyBase: gatewayTheme.fontFamilyBase,
  colorBrandBackground: '#3978ed', colorBrandBackgroundHover: '#508bf5', colorBrandBackgroundPressed: '#2864d3',
  colorBrandForeground1: '#91baff', colorBrandForeground2: '#91baff', colorBrandStroke1: '#699df4',
  colorNeutralForeground1: '#e2eaf6', colorNeutralForeground2: '#b4c3d8', colorNeutralForeground3: '#98abc4',
  colorNeutralBackground1: '#17253b', colorNeutralBackground2: '#101c2f', colorNeutralBackground3: '#1d2d45',
  colorNeutralStroke1: '#435571', colorNeutralStroke2: '#2d405b',
  borderRadiusMedium: '8px', borderRadiusLarge: '12px', borderRadiusXLarge: '16px',
};
