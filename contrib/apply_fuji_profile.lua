--[[

    apply_fuji_profile.lua - Apply a fujifilm recipe to a RAF image.

    Copyright (C) 2025 Jackson Myers <jacksonthomyers@gmail.com>.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]
--[[
    image_stack - export a stack of images and process them, returning the result

    This script provides another storage (export target) for darktable.  Selected
    images are exported in the specified format to temporary storage.  The images are aligned
    if the user requests it. When the images are ready, imagemagick is launched and uses
    the selected evaluate-sequence operator to process the images.  The output file is written
    to a filename representing the imput files in the format specified by the user.  The resulting 
    image is imported into the film roll.  The source images can be tagged as part of the file 
    creation so that  a user can later find the contributing images.

    ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
    * rawji - https://github.com/pinpox/rawji

    USAGE
    * require this script from your main lua file
    * select the images to process with image_stack
    * in the export dialog select "image stack" and select the format and bit depth for the
      exported image
    * Select whether the images need to be aligned.
    * Select the stack operator
    * Select the output format
    * Select whether to tag the source images used to create the resulting file
    * Specify executable locations if necessary
    * Press "export"
    * The resulting image will be imported

    NOTES
    Mean is a fairly quick operation.  On my machine (i7-6800K, 16G) it takes a few seconds.  Median, on the other hand
    takes approximately 10x longer to complete.  Processing 10 and 12 image stacks took over a minute.  I didn't test all
    the other functions, but the ones I did fell between Mean and Median performance wise.

    BUGS, COMMENTS, SUGGESTIONS
    * Send to Bill Ferguson, wpferguson@gmail.com

    CHANGES

    THANKS
    * Thanks to Pat David and his blog entry on blending images, https://patdavid.net/2013/05/noise-removal-in-photos-with-median_6.html
]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local dtsys = require "lib/dtutils.system"
local gettext = dt.gettext.gettext
local job = nil

-- path separator constant
local PS = dt.configuration.running_os == "windows" and "\\" or "/"

-- works with LUA API version 5.0.0
du.check_min_api_version("7.0.0", "apply_fuji_profile") 

local function _(msgid)
    return gettext(msgid)
end

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("apply fuji profile"),
  purpose = _("Apply a fujifilm recipe to a RAF file."),
  author = "Jackson Myers <jacksonthomyers@gmail.com",
  -- help = "https://docs.darktable.org/lua/stable/lua.scripts.manual/scripts/contrib/image_stack"
}

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil -- only required for libs since the destroy_method only hides them

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
--  GUI definitions
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

local label_recipe_options= dt.new_widget("section_label"){
  label = _('recipe options')
}

-- Film Sim
local cmbx_film_sim = dt.new_widget("combobox"){
    label = _('Film Simulation'),
    tooltip =_('Fujifilm simulation to be used'),
    -- value = dt.preferences.read("fuji_profile", "film_sim", "integer"),
    _("provia"), _("velvia"), _("astia"), _("classic-chrome"), _("proneghi"), _("pronegstd"), _("acros"), _("acros-ye"), _("acros-r"), _("acros-g"), _("monochrome"), _("sepia"), _("eterna"), _("eterna-bleach"),
    -- reset_callback = function(self)
    --    self.value = dt.preferences.read("align_image_stack", "def_grid_size", "integer")
    -- end
}
-- Exposure Compensation (-5.0 to +5.0)
local slider_exp_comp = dt.new_widget("slider"){
  label = _('Exposure Compensation'),
  value = dt.preferences.read("fuji_profile", "exp_comp", "float"),
  step = 1,
  digits = 1,
  hard_max = 5.0,
  hard_min = -5.0
}
-- Highlights (-4 to +4)
local slider_highlights = dt.new_widget("slider"){
  label = _('Highlights'),
  value = dt.preferences.read("fuji_profile", "highlights", "float"),
  step = 1,
  digits = 1,
  hard_max = 4.0,
  hard_min = -4.0
}
-- Shadows (-2 to +4)
local slider_shadows = dt.new_widget("slider"){
  label = _('Shadows'),
  value = dt.preferences.read("fuji_profile", "Shadows", "float"),
  step = 1,
  digits = 1,
  hard_max = 4.0,
  hard_min = -2.0
}
-- Sharpness (-4 to +4)
local slider_sharpness = dt.new_widget("slider"){
  label = _('Sharpness'),
  value = dt.preferences.read("fuji_profile", "sharpness", "float"),
  step = 1,
  digits = 1,
  hard_max = 4.0,
  hard_min = -4.0
}
-- Color (-4 to +4)
local slider_colors = dt.new_widget("slider"){
  label = _('Colors'),
  value = dt.preferences.read("fuji_profile", "colors", "float"),
  step = 1,
  digits = 1,
  hard_max = 4.0,
  hard_min = -4.0
}
-- Noise Reduction (-4 to +4)
local slider_nr = dt.new_widget("slider"){
  label = _('Noise Reduction'),
  value = dt.preferences.read("fuji_profile", "noise_reduction", "float"),
  step = 1,
  digits = 1,
  hard_max = 4.0,
  hard_min = -4.0
}
-- Grain (off/weak/strong)
local cmbx_grain = dt.new_widget("combobox"){
    label = _('Grain'),
    -- value = dt.preferences.read("fuji_profile", "film_sim", "integer"),
    _("off"), _("weak"), _("strong")
}
-- Color Chrome (off/weak/strong)
local cmbx_color_chrome = dt.new_widget("combobox"){
    label = _('Color Chrome'),
    -- value = dt.preferences.read("fuji_profile", "film_sim", "integer"),
    _("off"), _("weak"), _("strong")
}
-- Dynamic Range (100/200/400)
local cmbx_dr = dt.new_widget("combobox"){
    label = _('Dynamic Range'),
    -- value = dt.preferences.read("fuji_profile", "film_sim", "integer"),
    _(100), _(200), _(400)
}
-- White Balance (auto/daylight/shade)
local cmbx_wb = dt.new_widget("combobox"){
    label = _('White Balance'),
    -- value = dt.preferences.read("fuji_profile", "film_sim", "integer"),
    _("auto"), _("daylight"), _("shade")
}




local apply_fuji_profile_widget = dt.new_widget("box"){
  orientation = "vertical",
  label_recipe_options,
  cmbx_film_sim,
  slider_exp_comp,
  slider_highlights,
  slider_shadows,
  slider_sharpness,
  slider_colors,
  slider_nr,
  cmbx_grain,
  cmbx_color_chrome,
  cmbx_dr,
  cmbx_wb
}

local executables = {"rawji"}

if dt.configuration.running_os ~= "linux" then
  apply_fuji_profile_widget[#apply_fuji_profile_widget + 1] = df.executable_path_widget(executables)
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
--  local functions
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

local function show_status(storage, image, format, filename, number, total, high_quality, extra_data)
    dt.print(string.format(_("export image %i/%i"), number, total))
end

-- read the gui and populate the rawji arguments

local function get_rawji_arguments()

  local rawji_args = ""

  -- Film simulation mapping (GUI uses dashes, rawji expects no dashes)
  local film_sims = {"provia", "velvia", "astia", "classicchrome", "proneghi", "pronegstd",
                     "acros", "acrosye", "acrosr", "acrosg", "monochrome", "sepia",
                     "eterna", "eternableach"}
  if cmbx_film_sim.selected > 0 then
    rawji_args = rawji_args .. " --film-sim " .. film_sims[cmbx_film_sim.selected]
  end

  -- Exposure compensation
  if slider_exp_comp.value ~= 0 then
    rawji_args = rawji_args .. " --exposure " .. tostring(slider_exp_comp.value)
  end

  -- Highlights
  if slider_highlights.value ~= 0 then
    rawji_args = rawji_args .. " --highlights " .. tostring(math.floor(slider_highlights.value))
  end

  -- Shadows
  if slider_shadows.value ~= 0 then
    rawji_args = rawji_args .. " --shadows " .. tostring(math.floor(slider_shadows.value))
  end

  -- Sharpness
  if slider_sharpness.value ~= 0 then
    rawji_args = rawji_args .. " --sharpness " .. tostring(math.floor(slider_sharpness.value))
  end

  -- Color
  if slider_colors.value ~= 0 then
    rawji_args = rawji_args .. " --color " .. tostring(math.floor(slider_colors.value))
  end

  -- Noise reduction
  if slider_nr.value ~= 0 then
    rawji_args = rawji_args .. " --nr " .. tostring(math.floor(slider_nr.value))
  end

  -- Grain
  local grains = {"off", "weak", "strong"}
  if cmbx_grain.selected > 0 then
    rawji_args = rawji_args .. " --grain " .. grains[cmbx_grain.selected]
  end

  -- Color chrome
  local color_chromes = {"off", "weak", "strong"}
  if cmbx_color_chrome.selected > 0 then
    rawji_args = rawji_args .. " --color-chrome " .. color_chromes[cmbx_color_chrome.selected]
  end

  -- Dynamic range
  local drs = {"100", "200", "400"}
  if cmbx_dr.selected > 0 then
    rawji_args = rawji_args .. " --dynamic-range " .. drs[cmbx_dr.selected]
  end

  -- White balance
  local wbs = {"auto", "daylight", "shade"}
  if cmbx_wb.selected > 0 then
    rawji_args = rawji_args .. " --white-balance " .. wbs[cmbx_wb.selected]
  end

  return rawji_args
end

-- extract, and sanitize, an image list from the supplied image table

local function extract_image_list(image_table)
  local img_list = ""
  local result = {}

  for img,expimg in pairs(image_table) do
    table.insert(result, expimg)
  end
  table.sort(result)
  for _,exp_img in ipairs(result) do
    img_list = img_list .. " " .. df.sanitize_filename(exp_img)
  end
  return img_list, #result
end

-- don't leave files laying around the operating system

local function cleanup(img_list)
  dt.print_log("image list is " .. img_list)
  files = du.split(img_list, " ")
  for _,f in ipairs(files) do
    f = string.gsub(f, '[\'\"]', "")
    os.remove(f)
  end
end

-- List files based on a search pattern.  This is cross platform compatible
-- but the windows version is recursive in order to get ls type listings.
-- Normally this shouldn't be a problem, but if you use this code just beware.
-- If you want to do it non recursively, then remove the /s argument from dir
-- and grab the path component from the search string and prepend it to the files
-- found.

local function list_files(search_string)
  local ls = "ls "
  local files = {}
  local dir_path = nil
  local count = 1

  if dt.configuration.running_os == "windows" then
    ls = "dir /b/s "
    search_string = string.gsub(search_string, "/", "\\\\")
  end

  local f = io.popen(ls .. search_string)
  if f then
    local found_file = f:read()
    while found_file do 
      files[count] = found_file
      count = count + 1
      found_file = f:read()
    end
    f:close()
  end
  return files
end

-- create a filename from a multi image set.  The image list is sorted, then
-- combined with first and last if more than 3 images or a - separated list
-- if three images or less.

local function make_output_filename(image_table)
  local images = {}
  local cnt = 1
  local max_distinct_names = 3
  local name_separator = "-"
  local outputFileName = nil
  local result = {}

  for img,expimg in pairs(image_table) do
    table.insert(result, expimg)
  end
  table.sort(result)
  for _,img in pairs(result) do
    images[cnt] = df.get_basename(img)
    cnt = cnt + 1
  end

  cnt = cnt - 1

  if cnt > 1 then
    if cnt > max_distinct_names then
      -- take the first and last
      outputFileName = images[1] .. name_separator .. images[cnt]
    else
      -- join them
      outputFileName = du.join(images, name_separator)
    end
  else
    -- return the single name
    outputFileName = images[cnt]
  end

  return outputFileName
end

-- get the path where the collection is stored

local function extract_collection_path(image_table)
  local collection_path = nil
  for i,_ in pairs(image_table) do
    collection_path = i.path
    break
  end
  return collection_path
end

-- copy an images database attributes to another image.  This only
-- copies what the database knows, not the actual exif data in the 
-- image itself.

-- local function copy_image_attributes(from, to, ...)
--   local args = {...}
--   if #args == 0 then
--     args[1] = "all"
--   end
--   if args[1] == "all" then
--     args[1] = "rating"
--     args[2] = "colors"
--     args[3] = "exif"
--     args[4] = "meta"
--     args[5] = "GPS"
--   end
--   for _,arg in ipairs(args) do
--     if arg == "rating" then
--       to.rating = from.rating
--     elseif arg == "colors" then
--       to.red = from.red
--       to.blue = from.blue
--       to.green = from.green
--       to.yellow = from.yellow
--       to.purple = from.purple
--     elseif arg == "exif" then
--       to.exif_maker = from.exif_maker
--       to.exif_model = from.exif_model
--       to.exif_lens = from.exif_lens
--       to.exif_aperture = from.exif_aperture
--       to.exif_exposure = from.exif_exposure
--       to.exif_focal_length = from.exif_focal_length
--       to.exif_iso = from.exif_iso
--       to.exif_datetime_taken = from.exif_datetime_taken
--       to.exif_focus_distance = from.exif_focus_distance
--       to.exif_crop = from.exif_crop
--     elseif arg == "GPS" then
--       to.elevation = from.elevation
--       to.longitude = from.longitude
--       to.latitude = from.latitude
--     elseif arg == "meta" then
--       to.publisher = from.publisher
--       to.title = from.title
--       to.creator = from.creator
--       to.rights = from.rights
--       to.description = from.description
--     else
--       dt.print_error("Unrecognized option to copy_image_attributes: " .. arg)
--     end
--   end
-- end

local function stop_job()
  job.valid = false
end

local function destroy()
  dt.destroy_storage("module_image_stack")
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
--  main program
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

local function apply_fuji_profile(storage, image_table, extra_data)

  local tmp_dir = dt.configuration.tmp_dir .. PS
  local image_count = 0
  local collection_path = nil
  local processed_files = {}

  -- Count images and get collection path
  for image, _ in pairs(image_table) do
    image_count = image_count + 1
    if not collection_path then
      collection_path = image.path
    end
  end

  local percent_step = 1 / image_count
  job = dt.gui.create_job(_("apply_fuji_profile"), true, stop_job)

  -- Get rawji executable
  local rawji_executable = df.check_if_bin_exists("rawji")
  if not rawji_executable then
    dt.print_error(_("rawji executable not found"))
    job.valid = false
    return
  end

  -- Get rawji arguments
  local rawji_args = get_rawji_arguments()

  -- Process each image
  for image, exported in pairs(image_table) do
    -- Use the original RAF file, not the exported version
    local raf_file = image.path .. PS .. image.filename

    -- Generate output filename based on original image name
    local base_name = df.get_basename(image.filename)
    local output_file = tmp_dir .. base_name .. "_rawji.jpg"

    -- Build rawji command (using original RAF file)
    local rawji_command = rawji_executable .. rawji_args .. " " ..
                         df.sanitize_filename(raf_file) .. " " ..
                         df.sanitize_filename(output_file)

    dt.print_log("Running: " .. rawji_command)

    -- Execute rawji
    local result = dtsys.external_command(rawji_command)

    if result == 0 then
      table.insert(processed_files, output_file)
      dt.print(_("Processed: ") .. image.filename)
    else
      dt.print_error(_("Failed to process: ") .. image.filename)
    end

    job.percent = job.percent + percent_step
  end

  -- Import processed images back into darktable
  if #processed_files > 0 then
    dt.print(string.format(_("Importing %d processed images..."), #processed_files))

    for i, file in ipairs(processed_files) do
      -- Create unique filename in the collection path
      local import_filename = df.create_unique_filename(collection_path .. PS .. df.get_filename(file))

      -- Move file from temp to collection, then import
      df.file_move(file, import_filename)
      local imported_image = dt.database.import(import_filename)

      if imported_image then
        -- Add a tag to identify it was processed by rawji
        local created_tag = dt.tags.create(_("created with|apply_fuji_profile"))
        dt.tags.attach(created_tag, imported_image)
        dt.print_log("Imported: " .. import_filename)
      else
        dt.print_error(_("Failed to import: ") .. file)
      end
    end
  end

  job.valid = false
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
--  darktable integration
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

-- dt.preferences.register("apply_fuji_profile", "align_use_gpu", -- name
--   "bool",                                                     -- type
--   _('align image stack: use GPU for remapping'),               -- label
--   _('set the GPU remapping for image align'),                 -- tooltip
--   false)

dt.register_storage("module_apply_fuji_profile", _("apply fuji profile"), show_status, apply_fuji_profile, nil, nil, apply_fuji_profile_widget)

script_data.destroy = destroy

return script_data
