package com.example.blntextspeech;

import android.os.Bundle;
import android.view.KeyEvent;

import androidx.appcompat.app.AppCompatActivity;
import androidx.navigation.NavController;
import androidx.navigation.Navigation;
import androidx.navigation.ui.AppBarConfiguration;
import androidx.navigation.ui.NavigationUI;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;
import androidx.coordinatorlayout.widget.CoordinatorLayout;

import com.example.blntextspeech.databinding.ActivityMainBinding;
import com.google.android.material.appbar.AppBarLayout;

public class MainActivity extends AppCompatActivity {
    private AppBarConfiguration appBarConfiguration;
    private ActivityMainBinding binding;
    private boolean readerMode;
    private ReaderKeyHandler readerKeyHandler;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        binding = ActivityMainBinding.inflate(getLayoutInflater());
        setContentView(binding.getRoot());
        setSupportActionBar(binding.toolbar);

        NavController navController = Navigation.findNavController(this, R.id.nav_host_fragment_content_main);
        appBarConfiguration = new AppBarConfiguration.Builder(R.id.FirstFragment).build();
        NavigationUI.setupActionBarWithNavController(this, navController, appBarConfiguration);
    }

    public void setReaderMode(boolean readerMode) {
        this.readerMode = readerMode;
        binding.appBar.setVisibility(readerMode ? android.view.View.GONE : android.view.View.VISIBLE);
        android.view.View content = findViewById(R.id.main_content);
        CoordinatorLayout.LayoutParams params = (CoordinatorLayout.LayoutParams) content.getLayoutParams();
        params.setBehavior(readerMode ? null : new AppBarLayout.ScrollingViewBehavior());
        content.setLayoutParams(params);
        content.requestLayout();
        WindowInsetsControllerCompat controller =
                WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        if (readerMode) {
            controller.setSystemBarsBehavior(
                    WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            controller.hide(WindowInsetsCompat.Type.systemBars());
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars());
        }
    }

    public void setReaderKeyHandler(ReaderKeyHandler readerKeyHandler) {
        this.readerKeyHandler = readerKeyHandler;
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int keyCode = event.getKeyCode();
        boolean volumeKey = keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
                keyCode == KeyEvent.KEYCODE_VOLUME_DOWN;
        if (readerMode && volumeKey && readerKeyHandler != null &&
                readerKeyHandler.onReaderKey(event)) {
            return true;
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    public boolean onSupportNavigateUp() {
        NavController navController = Navigation.findNavController(this, R.id.nav_host_fragment_content_main);
        return NavigationUI.navigateUp(navController, appBarConfiguration) || super.onSupportNavigateUp();
    }

    public interface ReaderKeyHandler {
        boolean onReaderKey(KeyEvent event);
    }
}
