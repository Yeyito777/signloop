import { createContext, useContext } from 'react';

export const SoftwarePreviewContext = createContext(false);
export const useSoftwarePreview = () => useContext(SoftwarePreviewContext);
