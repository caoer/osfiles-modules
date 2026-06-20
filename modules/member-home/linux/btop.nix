_: {
  programs.btop = {
    enable = true;
    settings = {
      shown_boxes = "proc cpu";
      update_ms = 3000;
      proc_sorting = "pid";
      proc_reversed = true;
      presets = "cpu:1:default,proc:0:default cpu:0:default,mem:0:default,net:0:default cpu:0:block,net:0:tty";
      save_config_on_exit = false;
    };
  };
}
