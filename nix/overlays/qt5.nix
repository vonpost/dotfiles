qt5 = pkgs.qt5.overrideScope (super: self: { 
  qtwebengine = super.qtwebengine.overrideAttrs (y: { 
    postInstall = '' 
              ... 
              ''; 
  }); 
}); 
